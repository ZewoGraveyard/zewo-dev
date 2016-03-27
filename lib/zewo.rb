require 'zewo/version'

require 'thor'
require 'rubygems'
require 'json'
require 'net/http'
require 'uri'
require 'fileutils'
require 'pathname'
require 'xcodeproj'
require 'colorize'
require 'thread'
require 'thwait'

def silent_cmd(cmd)
  system("#{cmd} > /dev/null 2>&1")
end

module Zewo
  class App < Thor
    class Repo
      attr_reader :name
      @name = nil
      attr_reader :data
      @data = nil

      @xcodeproj = nil

      def initialize(name, data = nil)
        @name = name
        @data = data
      end

      def framework_target
        target_name = name.gsub('-OSX', '').tr('-', '_')
        xcode_project.native_targets.find { |t| t.name == target_name } || xcode_project.new_target(:framework, target_name, :osx)
      end

      def test_target
        target_name = "#{framework_target.name}-Test"
        xcode_project.native_targets.find { |t| t.name == target_name } || xcode_project.new_target(:bundle, target_name, :osx)
      end

      def dir(ext = nil)
        r = name
        r = "#{r}/#{ext}" if ext
        r
      end

      def tests_dirname
        'Tests'
      end

      def xcode_dirname
        'XcodeDevelopment'
      end

      def xcode_project_path
        dir("#{xcode_dirname}/#{name}.xcodeproj")
      end

      def sources_dirname
        return 'Sources' if File.directory?(dir('Sources'))
        return 'Source'  if File.directory?(dir('Source'))
      end

      def xcode_project
        return @xcodeproj if @xcodeproj
        return Xcodeproj::Project.open(xcode_project_path) if File.exist?(xcode_project_path)
        Xcodeproj::Project.new(xcode_project_path)
      end

      def add_files(direc, current_group, main_target)
        Dir.glob(direc) do |item|
          next if item == '.' || item == '.DS_Store'

          if File.directory?(item)
            new_folder = File.basename(item)
            created_group = current_group.new_group(new_folder)
            add_files("#{item}/*", created_group, main_target)
          else
            item = item.split('/')[1..-1].unshift('..') * '/'
            i = current_group.new_file(item)
            main_target.add_file_references([i]) if item.include? '.swift'
          end
        end
      end

      def build_dependencies
        puts "Configuring dependencies for #{name}".green
        dependency_repos = File.read(dir('Package.swift')).scan(%r{/(?<=Zewo\/)(.*?)(?=\.git)/}).map(&:first)

        group = xcode_project.new_group('Subprojects')
        dependency_repos.each do |repo_name|
          repo = Repo.new(repo_name)
          project_reference = group.new_file(repo.xcode_project_path.to_s)
          project_reference.path = "../../#{project_reference.path}"
          framework_target.add_dependency(repo.framework_target) if framework_target
        end
        xcode_project.save
      end

      def configure_xcode_project
        @xcodeproj = nil
        silent_cmd("rm -rf #{dir(xcode_dirname)}")

        puts "Creating Xcode project #{name}".green

        framework_target.build_configurations.each do |configuration|
          framework_target.build_settings(configuration.name)['HEADER_SEARCH_PATHS'] = '/usr/local/include'
          framework_target.build_settings(configuration.name)['LIBRARY_SEARCH_PATHS'] = '/usr/local/lib'
          framework_target.build_settings(configuration.name)['ENABLE_TESTABILITY'] = 'YES'

          if File.exist?(dir('module.modulemap'))
            framework_target.build_settings(configuration.name)['MODULEMAP_FILE'] = '../module.modulemap'
          end
        end

        framework_target.frameworks_build_phase.clear

        xcode_project.new_file('../module.modulemap') if File.exist?(dir('module.modulemap'))

        if sources_dirname
          group = xcode_project.new_group(sources_dirname)
          add_files(dir("#{sources_dirname}/*"), group, framework_target)
        end

        test_target.resources_build_phase
        test_target.add_dependency(framework_target)

        test_target.build_configurations.each do |configuration|
          test_target.build_settings(configuration.name)['WRAPPER_EXTENSION'] = 'xctest'
          test_target.build_settings(configuration.name)['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/../../Frameworks @loader_path/../Frameworks'
          test_target.build_settings(configuration.name)['HEADER_SEARCH_PATHS'] = '/usr/local/include'
          test_target.build_settings(configuration.name)['LIBRARY_SEARCH_PATHS'] = '/usr/local/lib'
        end

        group = xcode_project.new_group(tests_dirname)
        add_files(dir("#{tests_dirname}/*"), group, test_target)

        xcode_project.save

        scheme = Xcodeproj::XCScheme.new
        scheme.configure_with_targets(framework_target, test_target)
        scheme.test_action.code_coverage_enabled = true
        scheme.save_as(xcode_project.path, framework_target.name, true)
      end
    end

    no_commands do
      def each_repo
        uri = URI.parse('https://api.github.com/orgs/Zewo/repos?per_page=200')

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        request = Net::HTTP::Get.new(uri.request_uri)

        blacklist = %w(
          'Core',
          'GrandCentralDispatch',
          'JSONParserMiddleware',
          'LoggerMiddleware',
          'Middleware',
          'SSL',
          'SwiftZMQ',
          'HTTPMiddleware'
        )

        response = http.request(request)

        if response.code == '200'
          result = JSON.parse(response.body).sort_by { |hsh| hsh['name'] }

          result.each do |doc|
            next if blacklist.include?(doc['name'])
            repo = Repo.new(doc['name'], doc)
            yield repo
          end
        else
          puts 'Error loading repositories'.red
        end
      end

      def each_repo_async
        threads = []
        each_repo do |repo|
          threads << Thread.new do
            yield(repo)
          end
        end
        ThreadsWait.all_waits(*threads)
      end

      def each_code_repo
        each_repo do |repo|
          next unless File.exist?(repo.dir('Package.swift'))
          yield repo
        end
      end

      def each_code_repo_async
        threads = []
        each_code_repo do |repo|
          threads << Thread.new do
            yield(repo)
          end
        end
        ThreadsWait.all_waits(*threads)
      end

      def verify_branches
        last_branch_name = nil
        each_repo do |repo|
          branch_name = `cd #{repo.dir}; git rev-parse --abbrev-ref HEAD`.delete("\n")
          if !last_branch_name.nil? && branch_name != last_branch_name
            puts "Branch mismatch. Branch of #{repo.name} does not match previous branch #{branch_name}".red
            return false
          end
          last_branch_name = branch_name
        end
        true
      end

      def prompt(question)
        printf "#{question} -  y/N: "
        p = STDIN.gets.chomp
        if p == 'y'
          true
        else
          false
        end
      end

      def uncommited_changes?(repo_name)
        !system("cd #{repo_name}; git diff --quiet HEAD")
      end

      def master_branch?(repo_name)
        `cd #{repo_name}; git rev-parse --abbrev-ref HEAD`
      end
    end

    desc :status, 'Get status of all repos'
    def status
      each_code_repo do |repo|
        str = repo.name
        str = uncommited_changes?(repo.name) ? str.red : str.green

        tag = `cd #{repo.name}; git describe --abbrev=0 --tags` || 'No tag'
        str += " (#{tag})"
        puts str.delete("\n")
      end
    end

    desc :tag, 'Tags all code repositories with the given tag. Asks to confirm for each repository'
    def tag(tag)
      each_code_repo do |repo|
        should_tag = prompt("create tag #{tag} in #{repo.name}?")
        if should_tag
          silent_cmd("cd #{repo.name} && git tag #{tag}")
          puts repo.name.green
        end
      end
    end

    desc :checkout, 'Checks out all code repositories to the latest patch release for the given tag/branch'
    option :branch
    option :tag
    def checkout
      if !options[:branch] && !options[:tag]
        puts 'Need to specify either --tag or --branch'.red
        return
      end

      each_code_repo do |repo|
        matched = nil

        if options[:tag]
          matched = `cd #{repo.name} && git tag`
                    .split("\n")
                    .select { |t| t.start_with?(options[:tag]) }
                    .last
        end

        matched = options[:branch] if options[:branch]
        if matched
          silent_cmd("cd #{repo.name} && git checkout #{matched}")
          puts "Checked out #{repo.name} at #{matched}".green
        else
          puts "No matching specifiers for #{repo.name}".red
        end
      end
    end

    desc :pull, 'git pull on all repos'
    def pull
      print "Updating all repositories...\n"
      each_code_repo_async do |repo|
        if uncommited_changes?(repo.name)
          print "Uncommitted changes in #{repo.name}. Not updating.".red + "\n"
          next
        end
        system("cd #{repo.name}; git pull")
      end
      puts 'Done!'
    end

    desc :make_projects, 'Makes Xcode projects for all modules'
    def make_projects
      each_code_repo(&:configure_xcode_project)

      each_code_repo(&:build_dependencies)
    end

    desc :init, 'Clones all Zewo repositories'
    def init
      use_ssh = prompt('Clone using SSH?')

      each_repo_async do |repo|
        print "Checking #{repo.name}..." + "\n"
        unless File.directory?(repo.name)
          print "Cloning #{repo.name}...".green + "\n"
          silent_cmd("git clone #{repo.data[use_ssh ? 'clone_url' : 'ssh_url']}")
        end
      end
      puts 'Done!'
    end
  end
end

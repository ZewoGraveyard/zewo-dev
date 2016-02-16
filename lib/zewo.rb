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
        target_name = name.gsub('-OSX', '').gsub('-', '_')
        xcode_project.native_targets.find { |t| t.name == target_name } || xcode_project.new_target(:framework, target_name, :osx)
      end

      def xcode_dir
        "#{name}/XcodeDevelopment"
      end

      def xcode_project_path
        "#{xcode_dir}/#{name}.xcodeproj"
      end

      def xcode_project
        return @xcodeproj if @xcodeproj
        if File.exist?(xcode_project_path)
          @xcodeproj = Xcodeproj::Project.open(xcode_project_path)
        else
          @xcodeproj = Xcodeproj::Project.new(xcode_project_path)
        end
        @xcodeproj
      end

      def sources_dir
        if File.directory?("#{name}/Sources")
          return 'Sources'
        elsif File.directory?("#{name}/Source")
          return 'Source'
        end
        nil
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
        dependency_repos = File.read("#{name}/Package.swift").scan(/(?<=Zewo\/)(.*?)(?=\.git)/).map(&:first)

        group = xcode_project.new_group('Subprojects')
        dependency_repos.each do |repo_name|
          repo = Repo.new(repo_name)
          project_reference = group.new_file("#{repo.xcode_project_path}")
          project_reference.path = "../../#{project_reference.path}"

          if framework_target
            framework_target.add_dependency(repo.framework_target)
          end
        end

        xcode_project.save
      end

      def configure_xcode_project
        @xcodeproj = nil
        silent_cmd("rm -rf #{xcode_dir}")

        puts "Creating Xcode project #{name}".green

        framework_target.build_configurations.each do |configuration|
          framework_target.build_settings(configuration.name)['HEADER_SEARCH_PATHS'] = '/usr/local/include'
          framework_target.build_settings(configuration.name)['LIBRARY_SEARCH_PATHS'] = '/usr/local/lib'

          if File.exist?("#{name}/module.modulemap")
            framework_target.build_settings(configuration.name)['MODULEMAP_FILE'] = '../module.modulemap'
          end
        end

        xcode_project.new_file('../module.modulemap') if File.exist?("#{name}/module.modulemap")

        if sources_dir
          group = xcode_project.new_group(sources_dir)
          add_files("#{name}/#{sources_dir}/*", group, framework_target)
        end

        xcode_project.save
      end
    end

    no_commands do
      def each_repo
        uri = URI.parse('https://api.github.com/orgs/Zewo/repos?per_page=200')

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        request = Net::HTTP::Get.new(uri.request_uri)

        blacklist = [
          'Core',
          'GrandCentralDispatch',
          'JSONParserMiddleware',
          'Levee',
          'LoggerMiddleware',
          'Middleware',
          'Mustache',
          'POSIXRegex',
          'SSL',
          'Sideburns',
          'SwiftZMQ',
          'WebSocket'
        ]

        response = http.request(request)

        if response.code == '200'
          result = JSON.parse(response.body).sort_by { |hsh| hsh['name'] }


          result.each do |doc|
            next if blacklist.include?(doc['name'])
            repo = Repo.new(doc['name'], doc)
            yield repo
          end
        else
          puts 'Error loading repositories'
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
          unless File.exist?("#{repo.name}/Package.swift")
            print "No Package.swift for #{repo.name}. Skipping." + "\n"
            next
          end
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
          branch_name = `cd #{repo.name}; git rev-parse --abbrev-ref HEAD`.gsub("\n", '')
          if !last_branch_name.nil? && branch_name != last_branch_name
            puts "Branch mismatch. Branch of #{repo.name} does not match previous branch #{branch_name}".red
            return false
          end
          last_branch_name = branch_name
        end
        true
      end

      def prompt(question)
        printf "#{question} -  press 'y' to continue: "
        p = STDIN.gets.chomp
        if p == 'y'
          true
        else
          puts 'Aborting..'
          false
        end
      end

      def uncommited_changes?(repo_name)
        !system("cd #{repo_name}; git diff --quiet HEAD")
      end

      def master_branch?(repo_name)
        name = `cd #{repo_name}; git rev-parse --abbrev-ref HEAD`
      end
    end

    desc :status, 'Get status of all repos'
    def status
      each_code_repo do |repo|
        str = repo.name
        if uncommited_changes?(repo.name)
          str = str.red
        else
          str = str.green
        end

        tag = `cd #{repo.name}; git describe --abbrev=0 --tags` || 'No tag'
        str += " (#{tag})"
        puts str.gsub("\n", '')
      end
    end

    desc :pull, 'git pull on all repos'
    def pull
      each_code_repo_async do |repo|
        print "Updating #{repo.name}..." + "\n"
        if uncommited_changes?(repo.name)
          print "Uncommitted changes in #{repo.name}. Not updating.".red + "\n"
          next
        end
        silent_cmd("cd #{repo.name}; git pull")
        print "Updated #{repo.name}".green + "\n"
      end
    end

    desc :push, 'git push on all repos'
    def push
      verify_branches

      each_code_repo_async do |repo|
        if uncommited_changes?(repo.name)
          print "Uncommitted changes in #{repo.name}. Skipping.." + "\n"
          next
        end
        print "Pushing #{repo.name}...".green + "\n"
        silent_cmd("cd #{repo.name}; git push")
      end
      print 'Done!' + "\n"
    end

    desc :init, 'Clones all Zewo repositories'
    def init
      each_repo_async do |repo|
        print "Checking #{repo.name}..." + "\n"
        unless File.directory?(repo.name)
          print "Cloning #{repo.name}...".green + "\n"
          silent_cmd("git clone #{repo.data['ssh_url']}")
        end
      end
      puts 'Done!'
    end

    desc :build, 'Clones all Zewo repositories'
    def build
      each_code_repo do |repo|
        unless File.directory?("#{repo.name}/Xcode")
          puts "Skipping #{repo.name}. No Xcode project".yellow
        end
        puts "Building #{repo.name}...".green

        if system("cd #{repo.name}/Xcode; set -o pipefail && xcodebuild -scheme \"#{repo.name}\" -sdk \"macosx\" -toolchain /Library/Developer/Toolchains/swift-latest.xctoolchain | xcpretty") == false
          puts "Error building. Maybe you're using the wrong Xcode? Try `sudo xcode-select -s /Applications/Xcode-Beta.app/Contents/Developer` if you have a beta-version of Xcode installed.".red

        end
      end
    end

    desc 'commit MESSAGE', 'Commits changes to all repos with the same commit message'
    def commit(message)
      return unless verify_branches

      each_code_repo do |repo|
        next unless uncommited_changes?(repo.name)
        puts repo.name
        puts '--------------------------------------------------------------'
        if uncommited_changes?(repo.name)
          puts 'Status:'.yellow
          system("cd #{repo.name}; git status")
          return unless prompt("Proceed with #{repo.name}?")
        end
      end

      each_code_repo do |repo|
        system("cd #{repo.name}; git add --all; git commit -am \"#{message}\"")
        puts "Commited #{repo.name}\n".green
      end

      if prompt('Push changes?'.red)
        push
      end
    end

    desc :make_projects, 'Makes projects'
    def make_projects
      each_code_repo(&:configure_xcode_project)

      each_code_repo(&:build_dependencies)
    end
  end
end

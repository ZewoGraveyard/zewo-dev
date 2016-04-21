require 'zewo/version'

require 'thor'
require 'json'
require 'net/http'
require 'uri'
require 'fileutils'
require 'pathname'
require 'xcodeproj'
require 'colorize'
require 'thread'
require 'thwait'

module Zewo
  class App < Thor
    class Repo
      @@repos = {}

      @@lock_branches = {'CURIParser' => '0.2.0', 'CHTTPParser' => '0.2.0', 'CLibvenice' => '0.2.0'}

      attr_reader :repo
      @repo
      attr_reader :organization
      @organization

      @xcode_project = nil
      @configured = false

      def initialize(repo, organization)
        @repo = repo
        @organization = organization
      end

      def clone
        puts "Cloning #{path}".green

        flags = ''

        if @@lock_branches[@repo]
          flags = "--branch #{@@lock_branches[@repo]}"
        end
        
        `git clone #{flags} https://github.com/#{@organization}/#{@repo} #{path} &> /dev/null`
      end

      def dependencies
        clone unless File.directory?(path)

        package_swift_contents = File.read("#{path}/Package.swift")

        # matches the packages like `VeniceX/Venice`
        regex = /https:\/\/github.com\/(.*\/*)"/
        matches = package_swift_contents.scan(regex).map(&:first).map { |e| e = e.chomp('.git') if e.end_with?('.git'); e }

        # splits VeniceX/Venice into ['VeniceX', 'Venice']
        splits = matches.map { |e| e.split('/', 2) }

        # creates a Repo using VeniceX as organization and Venice as repo
        repos = splits.map { |s| Repo.new(s[1], s[0]) }

        cached = repos.map do |m|
          # add it to global list of repositories if it isnt already in there
          @@repos["#{m.organization}/#{m.repo}"] = m unless @@repos["#{m.organization}/#{m.repo}"]
          @@repos["#{m.organization}/#{m.repo}"]
        end

        cached
      end

      def clone_dependencies
        # clone all dependencies that don't exist yet
        dependencies.each(&:clone_dependencies)
      end

      def setup_xcode_projects
        # create xcode project
        setup_xcode_project

        # recursively do the same for all dependencies
        dependencies.each(&:setup_xcode_projects)
      end

      def configure_xcode_projects
        # configure xcode project
        configure_xcode_project

        # recursively do the same for all dependencies
        dependencies.each(&:configure_xcode_projects)
      end

      def flat_dependencies
        result = dependencies

        dependencies.each do |dep|
          result += dep.flat_dependencies
        end

        result.uniq
      end


      def headers
        @headers ||= Dir.glob("#{path}/*.h")
      end

      def setup_xcode_project
        return if @xcode_project

        puts "Creating Xcode project for #{@organization}/#{@repo}".green

        @xcode_project = Xcodeproj::Project.new("#{xcode_project_path}")
        @xcode_project.initialize_from_scratch

        framework_target.build_configurations.each do |configuration|
          framework_target.build_settings(configuration.name)['HEADER_SEARCH_PATHS'] = '/usr/local/include'
          framework_target.build_settings(configuration.name)['LIBRARY_SEARCH_PATHS'] = '/usr/local/lib'
          framework_target.build_settings(configuration.name)['ENABLE_TESTABILITY'] = 'YES'

          if File.exist?("#{path}/module.modulemap")
            framework_target.build_settings(configuration.name)['MODULEMAP_FILE'] = '../module.modulemap'
          end
        end

        if sources_path
          group = @xcode_project.new_group('Sources')
          add_files("#{path}/#{sources_path}/*", group, framework_target)
        end

        test_target.resources_build_phase
        test_target.add_dependency(framework_target)

        test_target.build_configurations.each do |configuration|
          test_target.build_settings(configuration.name)['WRAPPER_EXTENSION'] = 'xctest'
          test_target.build_settings(configuration.name)['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/../../Frameworks @loader_path/../Frameworks'
          test_target.build_settings(configuration.name)['HEADER_SEARCH_PATHS'] = '/usr/local/include'
          test_target.build_settings(configuration.name)['LIBRARY_SEARCH_PATHS'] = '/usr/local/lib'
        end

        group = @xcode_project.new_group('Tests')
        add_files("#{path}/Tests/*", group, test_target)

        @xcode_project.save

        scheme = Xcodeproj::XCScheme.new
        scheme.configure_with_targets(framework_target, test_target)
        # scheme.test_action.code_coverage_enabled = true
        scheme.save_as(@xcode_project.path, framework_target.name, true)

        framework_target.frameworks_build_phase.clear
      end

      def configure_xcode_project
        return if @configured

        puts "Configuring Xcode project for #{path}".green

        group = @xcode_project.new_group('Subprojects')

        # This next block will move through the flattened dependencies of a project
        # to determine whether any of them have headers associated with their module maps.
        # If they do, each header must be added to the header search paths configuration
        flat_dependencies.select { |d| d.headers.count > 0 }.each do |header_dep|
          header_search_path = "../../../#{header_dep.path}"

          [framework_target, test_target].each do |target|
            target.build_configurations.each do |configuration|
              existing = target.build_settings(configuration.name)['HEADER_SEARCH_PATHS']
              unless existing.include? header_search_path
                existing += " #{header_search_path}"
                target.build_settings(configuration.name)['HEADER_SEARCH_PATHS'] = existing
              end
            end
          end
        end

        dependencies.each do |repo|
          next if repo.repo.end_with?('-OSX')

          project_reference = group.new_file(repo.xcode_project_path.to_s)
          project_reference.path = "../../../#{project_reference.path}"
          framework_target.add_dependency(repo.framework_target) if framework_target
        end
        @xcode_project.save
        @configured = true
      end

      def add_files(direc, current_group, main_target)
        Dir.glob(direc) do |item|
          next if item.start_with?('.')

          if File.directory?(item)
            new_folder = File.basename(item)
            created_group = current_group.new_group(new_folder)
            add_files("#{item}/*", created_group, main_target)
          else
            # Basically means "Remove Zewo from path and prepend '../'"
            item = item.split('/')[1..-1].unshift('..', '..') * '/'
            i = current_group.new_file(item)
            main_target.add_file_references([i]) if item.include? '.swift'
          end
        end
      end

      def xcode_project_path
        "#{path}/XcodeDevelopment/#{@repo}.xcodeproj"
      end

      def path
        "#{@organization}/#{@repo}"
      end

      def status
        `cd #{path}; git status`
      end

      def call(str)
        output = `cd #{path}; #{str} 2>&1`.chomp
        raise output unless $?.success?
        output
      end

      def uncommited_changes?
        begin
          call('git diff --quiet HEAD')
          return false
        rescue
          return true
        end
      end

      def master_branch?
        call('git rev-parse --abbrev-ref HEAD')
      end

      def tag
        return call('git describe --abbrev=0 --tags')
      rescue
        return 'No tags'
      end

      def branch
        call('git rev-parse --abbrev-ref HEAD')
      end

      def pull
        call('git pull')
      end

      def sources_path
        return 'Sources' if File.directory?("#{path}/Sources")
        return 'Source'  if File.directory?("#{path}/Source")
      end

      def framework_target
        target_name = repo.gsub('-OSX', '').gsub('-', '_')
        target_name = 'OperatingSystem' if target_name == 'OS'
        @xcode_project.native_targets.find { |t| t.name == target_name } || @xcode_project.new_target(:framework, target_name, :osx)
      end

      def test_target
        target_name = "#{framework_target.name}-Test"
        @xcode_project.native_targets.find { |t| t.name == target_name } || @xcode_project.new_target(:bundle, target_name, :osx)
      end

      def tag_lock
        @tag_lock ||= @@lock_branches[@repo]
      end

      def self::lock_branches
        @@lock_branches
      end

      # getter/setter for class variable
      def self::repos
        @@repos
      end

      def self::repos=(value)
        puts @@repos
        @@repos = value
      end
    end

    no_commands do
      def each_repo(include_lock_branches = true)
        Repo.repos.each_pair do |key, repo|
          next if !include_lock_branches && Repo::lock_branches.has_key?(repo.repo)
          yield key, repo
        end
      end

      def each_repo_async(include_lock_branches = true)
        threads = []
        Repo.repos.each_pair do |key, repo|
          next if !include_lock_branches && Repo::lock_branches.has_key?(repo.repo)
          threads << Thread.new do
            yield(key, repo)
          end
        end
        threads.each { |thr| thr.join }
      end

      def create_dotfile
        FileUtils.touch('.zewodev')
      end

      def has_dotfile
        File.exist?('.zewodev')
      end
     
    end

    attr_reader :top_node

    def initialize(*args)
      super
      @top_node = Repo.new('Flux', 'Zewo')
      Repo.repos['Zewo/Flux'] = @top_node

      command_name = nil

      args.each do |a|
        next unless a.is_a? Hash

        if a.key? :current_command
          command_name = a[:current_command].name
          break
        end
      end

      if !command_name.nil? && command_name.to_sym != :init
        unless has_dotfile
          puts 'zewodev has not been initialized in this directory. Run `zewodev init` do to so.'.red
          exit
        end
      end

      top_node.clone_dependencies
    end

    desc :init, 'Initializes the current directory as a Zewo development directory'
    def init
      create_dotfile
      invoke :rebuild_projects
    end

    desc :rebuild_projects, 'Rebuilds Xcode projects'
    def rebuild_projects
      top_node.setup_xcode_projects
      top_node.configure_xcode_projects
    end

    desc :status, 'Checks status of all repositories'
    def status
      each_repo do |key, repo|
        str = key
        branch = repo.branch
        str += " (#{repo.tag}) - #{repo.uncommited_changes? ? branch.red : branch.green}"

        if repo.tag_lock
          str += " Locked to #{repo.tag_lock}".yellow
        end

        puts str
      end
    end

    desc :pull, 'Pulls recent changes from all repositories'
    def pull
      puts "Pulling changes for all repositories..."
      each_repo_async(false) do |key, repo|
        begin
          output = repo.pull
          str = "#{key}:\n".green
          str += output
          str += "\n\n"
          puts str
        rescue Exception => e
          puts "#{key}: #{e.message.red}"
        end
      end
    end
  end
end

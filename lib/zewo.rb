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

def silent_cmd(cmd)
  system("#{cmd} > /dev/null 2>&1")
end

module Zewo
    class App < Thor
        class Repo
            @@repos = Hash.new()

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
                puts "Cloning #{@organization}/#{@repo}".green

                flags = ''
                flags = '--branch 0.2.0' if @repo == 'CURIParser' || @repo == 'CHTTPParser' || @repo == 'CLibvenice'
                `git clone #{flags} https://github.com/#{@organization}/#{@repo} &> /dev/null`
            end

            def dependencies

                unless File.directory?(@repo)
                    clone()
                end

                package_swift_contents = File.read("#{@repo}/Package.swift")

                # matches the packages like `VeniceX/Venice`
                regex = /https:\/\/github.com\/(.*\/*)"/
                matches = package_swift_contents.scan(regex).map(&:first).map { |e| e = e.chomp('.git') if e.end_with?('.git'); e }

                # splits VeniceX/Venice into ['VeniceX', 'Venice']
                splits = matches.map { |e| e.split('/', 2) }

                # creates a Repo using VeniceX as organization and Venice as repo
                repos = splits.map { |s| Repo.new(s[1], s[0]) }

                cached = repos.map { |m|
                    # add it to global list of repositories if it isnt already in there
                    @@repos["#{m.organization}/#{m.repo}"] = m unless @@repos["#{m.organization}/#{m.repo}"]
                    @@repos["#{m.organization}/#{m.repo}"]
                }

                return cached
            end

            def clone_dependencies
                # clone all dependencies that don't exist yet
                dependencies.each(&:clone_dependencies)
            end

            def setup_xcode_projects
                # create xcode project
                setup_xcode_project()

                # recursively do the same for all dependencies
                dependencies.each(&:setup_xcode_projects)
            end

            def configure_xcode_projects
                # configure xcode project
                configure_xcode_project()

                # recursively do the same for all dependencies
                dependencies.each(&:configure_xcode_projects)
            end

            def setup_xcode_project

                return if @xcode_project

                puts "Creating Xcode project for #{@organization}/#{@repo}".green

                @xcode_project = Xcodeproj::Project.new(xcode_project_path)

                framework_target.build_configurations.each do |configuration|
                    framework_target.build_settings(configuration.name)['HEADER_SEARCH_PATHS'] = '/usr/local/include'
                    framework_target.build_settings(configuration.name)['LIBRARY_SEARCH_PATHS'] = '/usr/local/lib'
                    framework_target.build_settings(configuration.name)['ENABLE_TESTABILITY'] = 'YES'

                    if File.exist?("#{@repo}/module.modulemap")
                        framework_target.build_settings(configuration.name)['MODULEMAP_FILE'] = '../module.modulemap'
                    end
                end

                if sources_path
                    group = @xcode_project.new_group('Sources')
                    add_files("#{@repo}/#{sources_path}/*", group, framework_target)
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
                add_files("#{@repo}/Tests/*", group, test_target)

                @xcode_project.save

                scheme = Xcodeproj::XCScheme.new
                scheme.configure_with_targets(framework_target, test_target)
                # scheme.test_action.code_coverage_enabled = true
                scheme.save_as(@xcode_project.path, framework_target.name, true)

                framework_target.frameworks_build_phase.clear
            end

            def configure_xcode_project

                return if @configured

                puts "Configuring Xcode project for #{@organization}/#{@repo}".green

                group = @xcode_project.new_group('Subprojects')

                dependencies.each do |repo|
                  next if repo.repo.end_with?('-OSX')

                  project_reference = group.new_file(repo.xcode_project_path.to_s)
                  project_reference.path = "../../#{project_reference.path}"
                  framework_target.add_dependency(repo.framework_target) if framework_target
                end
                @xcode_project.save
                @configured = true
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

            def xcode_project_path
                return "#{@repo}/XcodeDevelopment/#{@repo}.xcodeproj"
            end

            def sources_path
                return 'Sources' if File.directory?("#{@repo}/Sources")
                return 'Source'  if File.directory?("#{@repo}/Source")
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

            # getter/setter for class variable
            def Repo::repos
                @@repos
            end

            def Repo::repos= (value)
                puts @@repos
                @@repos = value
            end
        end

        no_commands do
        end

        desc :init, 'Clones all repositories from the topmost repository node.'
        def init
            top_node = Repo.new('Zewo', 'Flux')
            Repo.repos['Zewo/Flux'] = top_node

            top_node.clone_dependencies()
            top_node.setup_xcode_projects()
            top_node.configure_xcode_projects()
        end
    end
end

require 'fastlane/action'
require 'fastlane_core/print_table'
require_relative '../helper/emerge_helper'
require 'pathname'
require 'tmpdir'
require 'json'
require 'fileutils'

module Fastlane
  module Actions
    class EmergeAction < Action
      def self.run(params)
        api_token = params[:api_token]
        file_path = params[:file_path] || lane_context[SharedValues::XCODEBUILD_ARCHIVE]

        if file_path == nil
          file_path = Dir.glob("#{lane_context[SharedValues::SCAN_DERIVED_DATA_PATH]}/Build/Products/Debug-iphonesimulator/*.app").first
        end
        pr_number = params[:pr_number]
        branch = params[:branch]
        sha = params[:sha] || params[:build_id]
        base_sha = params[:base_sha] || params[:base_build_id]
        repo_name = params[:repo_name]
        gitlab_project_id = params[:gitlab_project_id]
        build_type = params[:build_type]
        order_file_version = params[:order_file_version]

        if file_path == nil || !File.exist?(file_path)
          UI.error("Invalid input file")
          return
        end

        # If the user provided a .app we will look for dsyms and package it into a zipped xcarchive
        if File.extname(file_path) == '.app'
          absolute_path = Pathname.new(File.expand_path(file_path))
          UI.message("A .app was provided, dSYMs will be looked for in #{absolute_path.dirname}")
          Dir.mktmpdir do |d|
            application_folder = "#{d}/archive.xcarchive/Products/Applications/"
            dsym_folder = "#{d}/archive.xcarchive/dSYMs/"
            FileUtils.mkdir_p application_folder
            FileUtils.mkdir_p dsym_folder
            if params[:linkmaps] && params[:linkmaps].length > 0
              linkmap_folder = "#{d}/archive.xcarchive/Linkmaps/"
              FileUtils.mkdir_p(linkmap_folder)
              params[:linkmaps].each do |l|
                FileUtils.cp(l, linkmap_folder)
              end
            end
            FileUtils.cp_r(file_path, application_folder)
            copy_dsyms("#{absolute_path.dirname}/*.dsym", dsym_folder)
            copy_dsyms("#{absolute_path.dirname}/*/*.dsym", dsym_folder)
            Xcodeproj::Plist.write_to_path({"NAME" => "Emerge Upload"}, "#{d}/archive.xcarchive/Info.plist")
            file_path = "#{absolute_path.dirname}/archive.xcarchive.zip"
            ZipAction.run(
              path: "#{d}/archive.xcarchive",
              output_path: file_path,
              exclude: [],
              include: [])
            UI.message("Archive generated at #{file_path}")
          end
        elsif File.extname(file_path) == '.xcarchive'
          zip_path = file_path + ".zip"
          if params[:linkmaps] && params[:linkmaps].length > 0
            linkmap_folder = "#{file_path}/Linkmaps/"
            FileUtils.mkdir_p(linkmap_folder)
            params[:linkmaps].each do |l|
              FileUtils.cp(l, linkmap_folder)
            end
          end
          Actions::ZipAction.run(
            path: file_path,
            output_path: zip_path,
            exclude: [],
            include: [])
          file_path = zip_path
        elsif File.extname(file_path) == '.zip' && params[:linkmaps] && params[:linkmaps].length > 0
          UI.error("Provided zipped archive and linkmaps, linkmaps will not be added to zip.")
        elsif !File.extname(file_path) == '.zip'
          UI.error("Invalid input file")
          return
        end

        filename = File.basename(file_path)
        url = 'https://api.emergetools.com/upload'
        params = {
          filename: filename,
        }
        if pr_number
          params[:prNumber] = pr_number
        end
        if branch
          params[:branch] = branch
        end
        if sha
          params[:sha] = sha
        end
        if base_sha
          params[:baseSha] = base_sha
        end
        if repo_name
          params[:repoName] = repo_name
        end
        if gitlab_project_id
          params[:gitlabProjectId] = gitlab_project_id
        end
        if order_file_version
          params[:orderFileVersion] = order_file_version
        end
        params[:buildType] = build_type || "development"
        FastlaneCore::PrintTable.print_values(
          config: params,
          hide_keys: [],
          title: "Summary for Emerge #{Fastlane::Emerge::VERSION}")
        resp = Faraday.post(url, params.to_json, {'Content-Type' => 'application/json', 'X-API-Token' => api_token})
        case resp.status
        when 200
          json = JSON.parse(resp.body)
          upload_id = json["upload_id"]
          upload_url = json["uploadURL"]
          Helper::EmergeHelper.perform_upload(upload_url, upload_id, file_path)
        when 403
          UI.error("Invalid API token")
        when 400
          UI.error("Invalid parameters")
          json = JSON.parse(resp.body)
          UI.error("Error: #{json["errorMessage"]}")
        else
          UI.error("Upload failed")
        end
      end

      def self.copy_dsyms(from, to)
        Dir.glob(from) do |filename|
          UI.message("Found dSYM: #{Pathname.new(filename).basename}")
          FileUtils.cp_r(filename, to)
        end
      end

      def self.description
        "Fastlane plugin for Emerge"
      end

      def self.authors
        ["Emerge Tools"]
      end

      def self.return_value
        # If your method provides a return value, you can describe here what it does
      end

      def self.details
        # Optional:
        ""
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :api_token,
                                  env_name: "EMERGE_API_TOKEN",
                               description: "An API token for Emerge",
                                  optional: false,
                                      type: String),
          FastlaneCore::ConfigItem.new(key: :file_path,
                                  env_name: "EMERGE_FILE_PATH",
                               description: "Path to the zipped xcarchive or app to upload",
                                  optional: true,
                                      type: String),
          FastlaneCore::ConfigItem.new(key: :linkmaps,
                                   description: "List of paths to linkmaps",
                                      optional: true,
                                          type: Array),
          FastlaneCore::ConfigItem.new(key: :pr_number,
                               description: "The PR number that triggered this upload",
                                  optional: true,
                                      type: String),
          FastlaneCore::ConfigItem.new(key: :branch,
                              description: "The current git branch",
                                optional: true,
                                    type: String),
          FastlaneCore::ConfigItem.new(key: :sha,
                              description: "The git SHA that triggered this build",
                                optional: true,
                                    type: String),
          FastlaneCore::ConfigItem.new(key: :base_sha,
                               description: "The git SHA of the base build",
                                  optional: true,
                                      type: String),
          FastlaneCore::ConfigItem.new(key: :build_id,
                               description: "A string to identify this build",
                                deprecated: "Replaced by `sha`",
                                  optional: true,
                                      type: String),
          FastlaneCore::ConfigItem.new(key: :base_build_id,
                               description: "Id of the build to compare with this upload",
                                deprecated: "Replaced by `base_sha`",
                                  optional: true,
                                      type: String),
          FastlaneCore::ConfigItem.new(key: :repo_name,
                               description: "Full name of the respository this upload was triggered from. For example: EmergeTools/Emerge",
                                  optional: true,
                                      type: String),
          FastlaneCore::ConfigItem.new(key: :gitlab_project_id,
                               description: "Id of the gitlab project this upload was triggered from",
                                  optional: true,
                                      type: Integer),
          FastlaneCore::ConfigItem.new(key: :build_type,
                               description: "String to identify the type of build such as release/development. Used to filter size graphs. Defaults to development",
                                  optional: true,
                                      type: String),
          FastlaneCore::ConfigItem.new(key: :order_file_version,
                               description: "Version of the order file to download",
                                  optional: true,
                                      type: String),
        ]
      end

      def self.is_supported?(platform)
        # Adjust this if your plugin only works for a particular platform (iOS vs. Android, for example)
        # See: https://docs.fastlane.tools/advanced/#control-configuration-by-lane-and-by-platform
        #
        # [:ios, :mac, :android].include?(platform)
        platform == :ios
      end
    end
  end
end

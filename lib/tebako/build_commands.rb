# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "thor"
require "json"

require_relative "application_builder"
require_relative "build_reporter"
require_relative "cache_manager"
require_relative "cache_catalog"
require_relative "layered_package"
require_relative "release_store"
require_relative "options_manager"
require_relative "runtime_builder"
require_relative "runtime_sdk"
require_relative "scenario_manager"
require_relative "single_file_bundle"

# rubocop:disable Metrics
# Tebako - an executable packager
module Tebako
  # Shared mechanics for the explicit runtime/application build commands.
  class BuildCommandBase < Thor
    class_option :prefix, type: :string, aliases: "-p", required: false,
                          desc: "Tebako packaging environment"
    class_option :devmode, type: :boolean, aliases: "-D", default: false,
                           desc: "Developer mode"
    class_option :explain, type: :boolean, default: false,
                           desc: "Explain which stages were rebuilt or reused"
    class_option :report, type: :string, enum: %w[json],
                          desc: "Emit a machine-readable build report"

    no_commands do
      def run_reported(extra_options)
        options_manager = Tebako::OptionsManager.new(options.to_h.merge(extra_options))
        cache_manager = Tebako::CacheManager.new(
          options_manager.deps,
          options_manager.source,
          options_manager.output_folder
        )
        cache_manager.version_cache_check unless options[:devmode]
        reporter = Tebako::BuildReporter.start(
          explain: options_manager.explain?,
          format: options_manager.report_format
        )
        success = false
        yield options_manager
        cache_manager.ensure_version_file
        success = true
      rescue Tebako::Error => e
        puts "Tebako script failed: #{e.message} [#{e.error_code}]"
        raise Thor::Error, e.message
      ensure
        reporter&.finish(success: success)
        Tebako::BuildReporter.current = nil
      end

      def configure_scenario(options_manager)
        scenario = Tebako::ScenarioManager.new(options_manager.root, options_manager.fs_entrance)
        scenario.configure_scenario
        options_manager.process_gemfile(scenario.gemfile_path) if scenario.with_gemfile
        scenario
      end
    end
  end

  # `tebako runtime build` command group.
  class RuntimeCommand < BuildCommandBase
    desc "build", "Build a reusable Tebako runtime"
    method_option :Ruby, type: :string, aliases: "-R", enum: Tebako::RubyVersion::RUBY_VERSIONS.keys
    method_option :output, type: :string, aliases: "-o", required: true
    method_option :"log-level", type: :string, aliases: "-l", enum: %w[error warn debug trace]
    method_option :"compression-level", type: :numeric
    method_option :patchelf, aliases: "-P", type: :boolean
    method_option :"sdk-output", type: :string,
                                 desc: "Write a verified runtime SDK archive after building"
    def build
      run_reported("mode" => "runtime", "root" => Dir.pwd, "entry-point" => "stub.rb") do |options_manager|
        scenario = configure_scenario(options_manager)
        descriptor = Tebako::RuntimeBuilder.new(options_manager, scenario).build
        export_sdk(options_manager, scenario, descriptor) if options["sdk-output"]
      end
    end

    desc "install SDK", "Verify, install, and activate a reusable Tebako runtime SDK"
    method_option :destination, type: :string, aliases: "-d", required: true
    method_option :sha256, type: :string, required: false,
                           desc: "Require the SDK archive to match this trusted SHA-256"
    def install(sdk)
      manifest = Tebako::RuntimeSdk.install(
        archive: sdk,
        destination: options["destination"],
        expected_sha256: options["sha256"]
      )
      destination = File.expand_path(options["destination"])
      puts "Installed runtime SDK #{manifest.fetch("runtime_identity")} at #{destination}"
      puts "Use this SDK for press commands with TEBAKO_PREFIX=#{destination}"
    rescue Tebako::Error => e
      raise Thor::Error, e.message
    end

    no_commands do
      def export_sdk(options_manager, scenario, descriptor)
        runtime = "#{options_manager.package}#{scenario.exe_suffix}"
        runtime_path = "runtime/#{File.basename(runtime)}"
        components = {
          runtime_path => runtime,
          Tebako::RuntimeDescriptor.path_for(runtime_path) => Tebako::RuntimeDescriptor.path_for(runtime)
        }
        sdk_dependency_paths(options_manager).each do |path|
          components["deps/#{path.delete_prefix("#{options_manager.deps}/")}"] = path
        end
        # The patched exts.mk links every press with `-L<prefix>/o -ltebako-fs`,
        # and libtebako-fs.a is the ONE library CMake builds into o/ instead of
        # deps/lib — without it an SDK install fails its first application
        # relink with "ld: library 'tebako-fs' not found".
        libtebako_fs = File.join(options_manager.output_folder, "libtebako-fs.a")
        raise Tebako::Error.new("Runtime build did not produce #{libtebako_fs}", 121) unless File.exist?(libtebako_fs)

        components["o/libtebako-fs.a"] = libtebako_fs
        sdk = options["sdk-output"]
        Tebako::RuntimeSdk.pack(
          output: sdk,
          components: components,
          descriptor: descriptor,
          runtime_path: runtime_path,
          build_prefix: options_manager.prefix
        )
        checksum = Tebako::RuntimeSdk.write_checksum(sdk)
        puts "Created runtime SDK checksum at #{checksum}"
      end

      def sdk_dependency_paths(options_manager)
        paths = %w[bin include lib share share.dummy].map { |name| File.join(options_manager.deps, name) }
        paths << options_manager.stash_dir
        paths << options_manager.ruby_src_dir
        paths.select { |path| File.exist?(path) }
      end
    end
  end

  # `tebako application build` command group.
  class ApplicationCommand < BuildCommandBase
    desc "build", "Build an application for an existing Tebako runtime"
    method_option :runtime, type: :string, aliases: "-u", required: true
    method_option :root, type: :string, aliases: "-r", required: true
    method_option :"entry-point", type: :string, aliases: ["-e", "--entry"], required: true
    method_option :output, type: :string, aliases: "-o", required: true
    method_option :cwd, type: :string, aliases: "-c"
    method_option :Ruby, type: :string, aliases: "-R", enum: Tebako::RubyVersion::RUBY_VERSIONS.keys
    method_option :"compression-level", type: :numeric
    method_option :"deployment-cache", type: :boolean, default: true
    method_option :"layer-strategy", type: :string, enum: %w[coarse semantic], default: "coarse"
    def build
      output = options["output"].sub(/\.tebako\z/, "")
      inferred_ruby = runtime_ruby_version(options["runtime"])
      extra = { "mode" => "application", "ref" => options["runtime"], "output" => output }
      extra["Ruby"] = inferred_ruby if inferred_ruby && !options["Ruby"]
      run_reported(extra) do |options_manager|
        scenario = configure_scenario(options_manager)
        Tebako::ApplicationBuilder.new(options_manager, scenario).build
      end
    end

    no_commands do
      def runtime_ruby_version(runtime)
        runtime_path = "#{runtime}#{Tebako::ScenarioManagerBase.new.exe_suffix}"
        descriptor_path = Tebako::RuntimeDescriptor.path_for(runtime_path)
        return unless File.file?(descriptor_path)

        Tebako::RuntimeDescriptor.load(descriptor_path).data.fetch("ruby_version")
      end
    end
  end

  # `tebako cache` inspection and maintenance command group.
  class CacheCommand < Thor
    class_option :prefix, type: :string, aliases: "-p", required: false,
                          desc: "Tebako packaging environment"
    class_option :json, type: :boolean, default: false,
                        desc: "Emit JSON"

    desc "list", "List cached build artifacts"
    def list
      render(catalog.entries.map(&:to_h))
    end

    desc "stats", "Show cache size and artifact counts"
    def stats
      render(catalog.stats)
    end

    desc "verify", "Verify checksummed cache artifacts"
    def verify
      invalid = catalog.verify
      render(
        "valid" => invalid.empty?,
        "invalid" => invalid.map(&:to_h)
      )
      raise Thor::Error, "#{invalid.length} corrupt cache artifact(s) found" unless invalid.empty?
    end

    desc "explain KEY", "Describe a cache artifact"
    def explain(key)
      matches = catalog.entries.select { |entry| entry.key == key || "#{entry.type}:#{entry.key}" == key }
      raise Thor::Error, "Cache artifact not found: #{key}" if matches.empty?

      render(matches.map(&:to_h))
    end

    desc "prune", "Remove least-recently-used or old cache artifacts"
    method_option :"max-size", type: :string, desc: "Maximum cache size, for example 20GB"
    method_option :"older-than", type: :string, desc: "Remove entries older than a duration, for example 30d"
    def prune
      raise Thor::Error, "Specify --max-size or --older-than" unless options["max-size"] || options["older-than"]

      removed = catalog.prune(
        max_size: parse_size(options["max-size"]),
        older_than: parse_duration(options["older-than"])
      )
      render("removed" => removed.map(&:to_h), "removed_bytes" => removed.sum(&:byte_size))
    end

    desc "remove KEY", "Remove one cache artifact"
    def remove(key)
      removed = catalog.remove(key)
      raise Thor::Error, "Cache artifact not found or currently in use: #{key}" if removed.empty?

      render("removed" => removed.map(&:to_h))
    end

    desc "clean", "Remove all fast-build caches"
    def clean
      catalog.clean
      render("cleaned" => true)
    end

    no_commands do
      def catalog
        @catalog ||= Tebako::CacheCatalog.new(Tebako::OptionsManager.new(options.to_h).deps)
      end

      def render(value)
        if options[:json]
          puts JSON.generate(value)
        else
          render_human(value)
        end
      end

      def render_human(value, indent = "")
        case value
        when Hash
          value.each do |key, child|
            if child.is_a?(Hash) || child.is_a?(Array)
              puts "#{indent}#{key}:"
              render_human(child, "#{indent}  ")
            else
              puts "#{indent}#{key}: #{child}"
            end
          end
        when Array
          value.each { |child| render_human(child, indent) }
        else
          puts "#{indent}#{value}"
        end
      end

      def parse_size(value)
        return unless value

        match = /\A(\d+(?:\.\d+)?)\s*(B|KB|MB|GB|TB)?\z/i.match(value)
        raise Thor::Error, "Invalid size: #{value}" unless match

        units = { nil => 1, "B" => 1, "KB" => 1024, "MB" => 1024**2, "GB" => 1024**3, "TB" => 1024**4 }
        (match[1].to_f * units.fetch(match[2]&.upcase)).to_i
      end

      def parse_duration(value)
        return unless value

        match = /\A(\d+(?:\.\d+)?)\s*([smhdw])\z/i.match(value)
        raise Thor::Error, "Invalid duration: #{value}" unless match

        units = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400, "w" => 604_800 }
        match[1].to_f * units.fetch(match[2].downcase)
      end
    end
  end

  # `tebako package` format inspection command group.
  class PackageCommand < Thor
    class_option :json, type: :boolean, default: false,
                        desc: "Emit JSON"

    desc "inspect PATH", "Inspect a Tebako application package"
    def inspect(path)
      render(package_inspection(path).to_h)
    rescue ArgumentError, SystemCallError => e
      raise Thor::Error, e.message
    end

    desc "verify PATH", "Verify package structure and report layer identities"
    def verify(path)
      inspection = package_inspection(path)
      render("valid" => true, "package" => inspection.to_h)
    rescue ArgumentError, SystemCallError => e
      render("valid" => false, "error" => e.message)
      raise Thor::Error, e.message
    end

    no_commands do
      def package_inspection(path)
        if Tebako::SingleFileBundle.bundle?(path)
          Tebako::SingleFileBundle.inspect(path)
        else
          Tebako::LayeredPackage.inspect(path)
        end
      end

      def render(value)
        if options[:json]
          puts JSON.generate(value)
        else
          render_human(value)
        end
      end

      def render_human(value, indent = "")
        case value
        when Hash
          value.each do |key, child|
            if child.is_a?(Hash) || child.is_a?(Array)
              puts "#{indent}#{key}:"
              render_human(child, "#{indent}  ")
            else
              puts "#{indent}#{key}: #{child}"
            end
          end
        when Array
          value.each { |child| render_human(child, indent) }
        end
      end
    end
  end

  # `tebako update` content-addressed activation and rollback command group.
  class UpdateCommand < Thor
    class_option :store, type: :string, default: ".tebako-releases",
                         desc: "Release object store"
    class_option :json, type: :boolean, default: false,
                        desc: "Emit JSON"

    desc "prepare PACKAGE", "Verify and import a package release"
    def prepare(package)
      render(release_store.import(package))
    rescue ArgumentError, SystemCallError => e
      raise Thor::Error, e.message
    end

    desc "apply RELEASE", "Atomically activate a prepared release"
    method_option :target, type: :string, required: true,
                           desc: "Application package path to replace"
    def apply(release)
      render(release_store.activate(release, options["target"]))
    rescue ArgumentError, SystemCallError => e
      raise Thor::Error, e.message
    end

    desc "rollback", "Atomically reactivate the previous release"
    method_option :target, type: :string, required: true,
                           desc: "Application package path to replace"
    def rollback
      render(release_store.rollback(options["target"]))
    rescue ArgumentError, SystemCallError => e
      raise Thor::Error, e.message
    end

    desc "status", "Show prepared and activated releases"
    def status
      render(release_store.status)
    end

    no_commands do
      def release_store
        @release_store ||= Tebako::ReleaseStore.new(options["store"])
      end

      def render(value)
        if options[:json]
          puts JSON.generate(value)
        else
          value.each do |key, child|
            puts "#{key}: #{child.is_a?(Array) || child.is_a?(Hash) ? JSON.generate(child) : child}"
          end
        end
      end
    end
  end
end
# rubocop:enable Metrics

# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "etc"
require "fileutils"

require_relative "build_reporter"
require_relative "codegen"
require_relative "error"
require_relative "packager"
require_relative "runtime_descriptor"
require_relative "version"

# rubocop:disable Metrics
# Tebako - an executable packager
module Tebako
  # Builds the reusable native runtime independently from application packaging.
  class RuntimeBuilder
    LINK_IDENTITY = ".tebako-runtime-link-identity"

    def initialize(options_manager, scenario_manager, command_runner: nil, file_generator: nil, finalizer: nil,
                   configure_command: nil, build_command: nil)
      @opts = options_manager
      @scm = scenario_manager
      @command_runner = command_runner || ->(environment, command) { system(environment, command) }
      @file_generator = file_generator
      @finalizer = finalizer
      @configured_command = configure_command
      @configured_build_command = build_command
    end

    def build
      current = current_descriptor
      if current
        Tebako::BuildReporter.record(
          stage: "runtime_build",
          status: "reused",
          reason: "runtime identity and native inputs are unchanged",
          key: current.identity
        )
        return current
      end

      started_at = monotonic_time
      generate_files
      merged_env = ENV.to_h.merge(@scm.b_env)
      Tebako.packaging_error(103) unless @command_runner.call(merged_env, configure_command)
      Tebako.packaging_error(104) unless @command_runner.call(merged_env, build_command)
      finalize
      descriptor = write_descriptor
      write_link_identity(descriptor)
      Tebako::BuildReporter.record(
        stage: "runtime_build",
        status: "checked",
        reason: "CMake evaluated the runtime dependency graph",
        duration: monotonic_time - started_at,
        details: descriptor ? { "runtime_identity" => descriptor.identity } : nil
      )
      descriptor
    end

    private

    def generate_files
      return @file_generator.call if @file_generator

      puts "-- Generating files"
      version_parts = Tebako::VERSION.split(".")
      Tebako::Codegen.generate_tebako_version_h(@opts, version_parts)
      Tebako::Codegen.generate_tebako_fs_cpp(@opts, @scm)
      Tebako::Codegen.generate_deploy_rb(@opts, @scm)
      Tebako::Codegen.generate_stub_rb(@opts) if %w[both runtime].include?(@opts.mode)
      Tebako::Codegen.generate_package_manifest(@opts, @scm)
    end

    def configure_command
      @configured_command || "cmake -DSETUP_MODE:BOOLEAN=OFF #{@opts.cfg_options} #{@opts.press_options}"
    end

    def build_command
      @configured_build_command || "cmake --build #{@opts.output_folder} --target tebako --parallel #{Etc.nprocessors}"
    end

    def finalize
      return @finalizer.call if @finalizer

      use_patchelf = @opts.patchelf? && @scm.linux_gnu?
      patchelf = use_patchelf ? "#{@opts.deps_bin_dir}/patchelf" : nil
      Tebako::Packager.finalize(@opts.ruby_src_dir, @opts.package, @opts.rv, patchelf, @opts.output_type_first)
    end

    def write_descriptor
      return unless %w[both runtime].include?(@opts.mode)
      return unless File.file?(runtime_output)

      descriptor = Tebako::RuntimeDescriptor.build(@opts)
      descriptor.write(Tebako::RuntimeDescriptor.path_for(runtime_output))
      descriptor
    end

    def current_descriptor
      return unless %w[both runtime].include?(@opts.mode)
      return unless File.file?(runtime_output)

      path = Tebako::RuntimeDescriptor.path_for(runtime_output)
      return unless File.file?(path)

      current = Tebako::RuntimeDescriptor.load(path)
      expected = Tebako::RuntimeDescriptor.build(@opts)
      current.identity == expected.identity && link_identity_current?(current.identity) ? current : nil
    rescue Tebako::Error
      nil
    end

    def write_link_identity(descriptor)
      return unless descriptor

      path = link_identity_path
      temporary = "#{path}.#{Process.pid}.tmp"
      File.binwrite(temporary, descriptor.identity)
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def link_identity_current?(identity)
      File.file?(link_identity_path) && File.binread(link_identity_path) == identity
    end

    def link_identity_path
      File.join(@opts.ruby_src_dir, LINK_IDENTITY)
    end

    def runtime_output
      "#{@opts.package}#{@scm.exe_suffix}"
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
# rubocop:enable Metrics

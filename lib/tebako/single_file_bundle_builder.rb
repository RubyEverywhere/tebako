# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "digest"
require "fileutils"

require_relative "application_builder"
require_relative "bundle_builder"
require_relative "finalized_runtime_cache"
require_relative "runtime_builder"
require_relative "runtime_descriptor"
require_relative "ruby_builder"
require_relative "single_file_bundle"

# Tebako - an executable packager
module Tebako
  # Builds one executable from a reusable runtime and layered application.
  class SingleFileBundleBuilder
    def initialize(options_manager, scenario_manager)
      @opts = options_manager
      @scm = scenario_manager
    end

    def build
      Tebako::BundleBuilder.new(@opts, @scm).build { build_changed }
    end

    private

    def build_changed
      runtime = finalized_runtime
      ensure_macho_link_inputs
      working_runtime = materialize_runtime(runtime)
      Tebako::SingleFileBundle.write(
        output,
        runtime: runtime,
        application: build_application(working_runtime),
        assembler: macho_assembler
      )
    end

    def build_application(working_runtime)
      application_options = @opts.derive("mode" => "both", "output" => working_runtime)
      Tebako::ApplicationBuilder.new(application_options, @scm).build
      "#{working_runtime}.tebako"
    end

    def finalized_runtime
      expected = Tebako::RuntimeDescriptor.build(runtime_options("unused"))
      @runtime_identity = expected.identity
      cache = Tebako::FinalizedRuntimeCache.new(
        cache_dir: @opts.finalized_runtime_cache_dir,
        descriptor: expected,
        exe_suffix: @scm.exe_suffix
      )
      cache.fetch do |runtime|
        Tebako::RuntimeBuilder.new(runtime_options(runtime), @scm).build
      end
    end

    def ensure_macho_link_inputs
      return unless @scm.macos?

      marker = File.join(@opts.ruby_src_dir, Tebako::RuntimeBuilder::LINK_IDENTITY)
      return if File.file?(marker) && File.binread(marker) == @runtime_identity

      base = File.join(@opts.output_folder, "bundle-work", output_identity, "macho-link-runtime")
      # The runtime build's final strip writes here with `strip -o`, which
      # cannot create missing directories — without this, a fresh identity dir
      # produces a "could not strip" warning and no byproduct file.
      FileUtils.mkdir_p(File.dirname(base))
      Tebako::RuntimeBuilder.new(runtime_options(base), @scm).build
    end

    def materialize_runtime(runtime)
      base = File.join(@opts.output_folder, "bundle-work", output_identity, "runtime")
      destination = "#{base}#{@scm.exe_suffix}"
      FileUtils.mkdir_p(File.dirname(base))
      FileUtils.cp(runtime, destination, preserve: true)
      FileUtils.cp(
        Tebako::RuntimeDescriptor.path_for(runtime),
        Tebako::RuntimeDescriptor.path_for(destination),
        preserve: true
      )
      base
    end

    def macho_assembler
      return unless @scm.macos?

      lambda do |target, application|
        Tebako::RubyBuilder.new(@opts.rv, @opts.ruby_src_dir).target_link_with_application(target, application)
      end
    end

    def runtime_options(runtime)
      @opts.derive(
        "mode" => "runtime",
        "output" => runtime,
        "root" => @opts.source,
        "entry-point" => "stub.rb",
        "Ruby" => @opts.ruby_ver
      )
    end

    def output_identity
      Digest::SHA256.hexdigest(File.expand_path(output))
    end

    def output
      "#{@opts.package}#{@scm.exe_suffix}"
    end
  end
end

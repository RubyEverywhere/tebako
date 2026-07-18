# frozen_string_literal: true

# Copyright (c) 2023-2025 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of the Tebako project.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "pathname"
require "fileutils"

require_relative "layered_package"
require_relative "options_manager"
require_relative "package_descriptor"
require_relative "packager"
require_relative "scenario_manager"

module Tebako
  # Tebako application package descriptor
  class PackagerLite
    def initialize(options_manager, scenario_manager)
      @opts = options_manager
      @scm = scenario_manager
      @scm.configure_scenario
    end

    def codegen
      puts "-- Generating files"
      Tebako::Codegen.generate_package_descriptor(@opts, @scm)
    end

    def create_implib
      rv = Tebako::RubyVersion.new(@opts.ruby_ver)
      bname = if @opts.mode == "application"
                @opts.ref
              else # @opts.mode == "both"
                @opts.package
              end
      Tebako::Packager.create_implib(@opts.ruby_src_dir, @opts.data_src_dir, bname, rv)
    end

    def create_package
      deploy
      FileUtils.rm_f(name)
      layered? ? create_layered_package : create_monolithic_package
      puts "Created tebako #{@opts.output_type_second} at \"#{name}\""
    end

    def create_monolithic_package
      Tebako::Packager.mkdwarfs(@opts.deps_bin_dir, name, @opts.data_src_dir, codegen, @opts.compression_level,
                                @opts.filesystem_cache_dir)
    end

    def create_layered_package
      descriptor = codegen
      layers = package_layers.map do |mount_point, source|
        image = layer_image(mount_point)
        Tebako::Packager.mkdwarfs(@opts.deps_bin_dir, image, source, nil, @opts.compression_level,
                                  @opts.filesystem_cache_dir)
        Tebako::LayeredPackage::Layer.new(mount_point: mount_point, path: image)
      end
      Tebako::LayeredPackage.write(name, descriptor: descriptor, layers: layers)
    end

    def deploy
      Tebako::Packager.init(@opts.stash_dir, @opts.data_src_dir, @opts.data_pre_dir, @opts.data_bin_dir,
                            preserve_bin: true)
      create_implib if @scm.msys?
      Tebako::Packager.deploy(@opts.data_src_dir, @opts.data_pre_dir, @opts.rv, @opts.root, @scm.fs_entrance, @opts.cwd,
                              @opts.bundle_cache_dir)
    end

    def name
      bname = Pathname.new(@opts.package).cleanpath.to_s
      @name ||= "#{bname}.tebako"
    end

    private

    # Layered application packages are emitted only alongside the matching
    # runtime. Standalone application mode remains compatible with older
    # runtimes, which expect one monolithic DwarFS image.
    def layered?
      @opts.mode == "both"
    end

    def package_layers
      api_version = @opts.rv.api_version
      {
        "local" => File.join(@opts.data_src_dir, "local"),
        "bin" => File.join(@opts.data_src_dir, "bin"),
        "lib/ruby/gems/#{api_version}" => File.join(@opts.data_src_dir, "lib", "ruby", "gems", api_version)
      }.select { |_mount_point, source| Dir.exist?(source) }
    end

    def layer_image(mount_point)
      safe_name = mount_point.tr("/", "-")
      FileUtils.mkdir_p(File.join(@opts.data_bin_dir, "layers"))
      File.join(@opts.data_bin_dir, "layers", "#{safe_name}.dwarfs")
    end
  end
end

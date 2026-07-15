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

require "bundler"
require_relative "error"

# Tebako - an executable packager
module Tebako
  # Ruby version
  class RubyVersion
    # Supported Ruby versions: latest patch release of each maintained line (3.2+ through 4.0).
    # Support for 2.7.x, 3.0.x and 3.1.x was dropped.
    RUBY_VERSIONS = {
      "3.2.11" => "b3eeabd6636f334531db3ffdc3229eb05e524740e6c84fdc043720573cf2f8b2",
      "3.3.11" => "59f0fafb1a59a05dc3765117af3fa68e153eb48254708549f321c1e9e078d7a0",
      "3.4.10" => "ecee2d072a14f2d14347dd56dfd8fe5c3130abf5117bfaacbda0f4ef9cc429ec",
      "4.0.6" => "837d299e8f7ddf2be31a229a7a7e019d354979825117989acb3b32b1a9be262a"
    }.freeze

    MIN_RUBY_VERSION_WINDOWS = "3.2.11"
    DEFAULT_RUBY_VERSION = "4.0.6"

    def initialize(ruby_version)
      @ruby_version = ruby_version.nil? ? DEFAULT_RUBY_VERSION : ruby_version

      run_checks
    end

    attr_reader :ruby_version

    def api_version
      @api_version ||= "#{@ruby_version.split(".")[0..1].join(".")}.0"
    end

    def extend_ruby_version
      @extend_ruby_version ||= [@ruby_version, RUBY_VERSIONS[@ruby_version]]
    end

    def lib_version
      @lib_version ||= "#{@ruby_version.split(".")[0..1].join}0"
    end

    # Version predicates are "this behavior applies to this version and newer", compared on
    # Gem::Version so they are correct for Ruby 4.x (major != 3) and for two-digit patch levels
    # (e.g. 3.3.11, 3.4.10). Ruby 4.0 satisfies the >= 3.x gates by design - it inherits the
    # latest (3.4+) build behavior.
    def ruby3x?
      @ruby3x ||= at_least?("3.0.0")
    end

    def ruby31?
      @ruby31 ||= at_least?("3.1.0")
    end

    def ruby32?
      @ruby32 ||= at_least?("3.2.0")
    end

    def ruby32only?
      @ruby32only ||= minor_line?(3, 2)
    end

    def ruby33?
      @ruby33 ||= at_least?("3.3.0")
    end

    def ruby33only?
      @ruby33only ||= minor_line?(3, 3)
    end

    def ruby3x7?
      @ruby3x7 ||= ruby34? ||
                   (ruby32only? && teeny >= 7) ||
                   (ruby33only? && teeny >= 7)
    end

    def ruby34?
      @ruby34 ||= at_least?("3.4.0")
    end

    def run_checks
      version_check_format
      version_check
      version_check_msys
    end

    def version_check
      return if RUBY_VERSIONS.key?(@ruby_version)

      raise Tebako::Error.new(
        "Ruby version #{@ruby_version} is not supported",
        110
      )
    end

    def version_check_format
      return if @ruby_version =~ /^\d+\.\d+\.\d+$/

      raise Tebako::Error.new("Invalid Ruby version format '#{@ruby_version}'. Expected format: x.y.z", 109)
    end

    def version_check_msys
      if Gem::Version.new(@ruby_version) < Gem::Version.new(MIN_RUBY_VERSION_WINDOWS) && ScenarioManagerBase.new.msys?
        raise Tebako::Error.new("Ruby version #{@ruby_version} is not supported on Windows", 111)
      end
    end

    private

    def gem_version
      @gem_version ||= Gem::Version.new(@ruby_version)
    end

    def segments
      @segments ||= gem_version.segments
    end

    def at_least?(version)
      gem_version >= Gem::Version.new(version)
    end

    def teeny
      segments[2].to_i
    end

    def minor_line?(major, minor)
      segments[0] == major && segments[1] == minor
    end
  end

  # Ruby version with Gemfile definition
  class RubyVersionWithGemfile < RubyVersion
    def initialize(ruby_version, gemfile_path)
      # Assuming that it does not attempt to load any gems or resolve dependencies
      # this can be done with any bundler version
      ruby_v = Bundler::Definition.build(gemfile_path, nil, nil).ruby_version&.versions
      if ruby_v.nil?
        super(ruby_version)
      else
        process_gemfile_ruby_version(ruby_version, ruby_v)
      end
    rescue Tebako::Error
      raise
    rescue StandardError => e
      Tebako.packaging_error(115, e.message)
    end

    def process_gemfile_ruby_version(ruby_version, ruby_v)
      puts "-- Found Gemfile with Ruby requirements #{ruby_v}"
      requirement = Gem::Requirement.new(ruby_v)

      if ruby_version.nil?
        process_gemfile_ruby_version_ud(requirement)
      else
        process_gemfile_ruby_version_d(ruby_version, requirement)
      end
      run_checks
    end

    def process_gemfile_ruby_version_d(ruby_version, requirement)
      current_version = Gem::Version.new(ruby_version)
      unless requirement.satisfied_by?(current_version)
        raise Tebako::Error.new("Ruby version #{ruby_version} does not satisfy requirement '#{requirement}'", 116)
      end

      @ruby_version = ruby_version
    end

    def process_gemfile_ruby_version_ud(requirement)
      available_versions = RUBY_VERSIONS.keys.map { |v| Gem::Version.new(v) }
      matching_version = available_versions.find { |v| requirement.satisfied_by?(v) }
      puts "-- Found matching Ruby version #{matching_version}" if matching_version

      unless matching_version
        raise Tebako::Error.new("No available Ruby version satisfies requirement #{requirement}",
                                116)
      end

      @ruby_version = matching_version.to_s
    end
  end
end

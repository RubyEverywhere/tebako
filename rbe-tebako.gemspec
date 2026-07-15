# frozen_string_literal: true

# Copyright (c)  2023-2025 [Ribose Inc](https://www.ribose.com).
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

require_relative "lib/tebako/version"

Gem::Specification.new do |spec|
  spec.name          = "rbe-tebako"
  spec.version       = Tebako::VERSION
  spec.authors       = ["Andrea Fomera", "Ribose Inc."]
  spec.email         = ["andrea.fomera@gmail.com"]
  spec.license       = "BSD-2-Clause"

  spec.summary = "Packager for Ruby executables (RubyEverywhere fork of tebako)"
  spec.description = <<~SUM
    rbe-tebako is the RubyEverywhere fork of tebako, an executable packager. It
    packages a set of files into a single executable binary that allows a user
    to run a selected file from the packaged software as if it is a mounted
    filesystem. This fork targets Ruby 3.2 through 4.0.
  SUM
  spec.homepage = "https://github.com/RubyEverywhere/tebako"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/RubyEverywhere/tebako"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files --recurse-submodules -z`.split("\x0").reject do |f|
      (f == __FILE__) ||
        f.match(%r{\A(?:(?:tests|tests-2|spec|deps|output|common\.env)/|\.(?:git|rspec|cirrus|tebako|rubocop))})
    end
  end

  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = %w[cmake exe ext include lib resources src tools/ci-scripts tools/cmake-scripts tools/includes]

  spec.add_dependency "bundler"
  spec.add_dependency "thor", "~> 1.2"
  spec.add_dependency "yaml", "~> 0.2.1"

  spec.add_development_dependency "debug"
  spec.add_development_dependency "hoe"
  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rdbg"
  spec.add_development_dependency "rspec", "~> 3.2"
  spec.add_development_dependency "rubocop", "~> 1.52"
  spec.add_development_dependency "rubocop-rubycw"
  spec.add_development_dependency "simplecov"
  spec.add_development_dependency "simplecov-cobertura"
end

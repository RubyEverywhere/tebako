# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require_relative "../lib/tebako/packager/patch_libraries"

RSpec.describe Tebako::Packager::PatchLibraries do
  def stub_brew_prefixes
    allow(Tebako::Packager::PatchHelpers).to receive(:get_prefix_macos) do |formula|
      yield formula if block_given?
      "/opt/homebrew/opt/#{formula}\n"
    end
  end

  it "installs every Homebrew formula referenced by the supported macOS linker" do
    brewfile = File.expand_path("../Brewfile", __dir__)
    declared = File.readlines(brewfile).filter_map { |line| line[/\Abrew "([^"]+)"/, 1] }
    required = []
    stub_brew_prefixes { |formula| required << formula }
    described_class.darwin_libraries("/tebako/deps/lib", double("RubyVersion", ruby31?: true), true)

    expect(declared).to include(*required.uniq)
  end

  it "links the compiled fmt dependency required by DwarFS" do
    stub_brew_prefixes

    libraries = described_class.darwin_libraries(
      "/tebako/deps/lib",
      double("RubyVersion", ruby31?: true),
      true
    )

    expect(libraries).to include("/opt/homebrew/opt/fmt/lib/libfmt.a")
  end
end

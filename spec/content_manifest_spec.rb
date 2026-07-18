# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "fileutils"
require "tmpdir"

require_relative "../lib/tebako/content_manifest"

# rubocop:disable Metrics/BlockLength
RSpec.describe Tebako::ContentManifest do
  describe ".digest_tree" do
    it "is stable when only file timestamps change" do
      Dir.mktmpdir do |root|
        path = File.join(root, "app.rb")
        File.write(path, "puts :ok")
        original = described_class.digest_tree(root)

        File.utime(Time.now + 60, Time.now + 60, path)

        expect(described_class.digest_tree(root)).to eq(original)
      end
    end

    it "changes when file contents or permissions change" do
      Dir.mktmpdir do |root|
        path = File.join(root, "app.rb")
        File.write(path, "puts :ok")
        original = described_class.digest_tree(root)

        File.write(path, "puts :changed")
        changed_content = described_class.digest_tree(root)
        File.chmod(0o755, path)

        expect(changed_content).not_to eq(original)
        expect(described_class.digest_tree(root)).not_to eq(changed_content)
      end
    end

    it "does not include excluded subtrees" do
      Dir.mktmpdir do |root|
        excluded = File.join(root, "output")
        FileUtils.mkdir_p(excluded)
        File.write(File.join(excluded, "package"), "first")
        original = described_class.digest_tree(root, excluded: [excluded])

        File.write(File.join(excluded, "package"), "second")

        expect(described_class.digest_tree(root, excluded: [excluded])).to eq(original)
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength

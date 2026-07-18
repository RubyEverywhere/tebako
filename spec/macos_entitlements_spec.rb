# frozen_string_literal: true

require "rexml/document"

RSpec.describe "macOS signing entitlements" do
  it "contains only the Hardened Runtime exceptions required by Ruby and native gems" do
    path = File.expand_path("../docs/macos-entitlements.plist", __dir__)
    dictionary = REXML::Document.new(File.binread(path)).elements["plist/dict"]
    entitlements = dictionary.elements.to_a.each_slice(2).to_h do |key, value|
      [key.text, value.name == "true"]
    end

    expect(entitlements).to eq(
      "com.apple.security.cs.allow-unsigned-executable-memory" => true,
      "com.apple.security.cs.disable-library-validation" => true
    )
  end
end

# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "fileutils"

# Tebako - an executable packager
module Tebako
  # Writes application packages made from independently reusable DwarFS images.
  module LayeredPackage
    MAGIC = "TEBAKOL1"
    Layer = Struct.new(:mount_point, :path, keyword_init: true)

    class << self
      def write(output, descriptor:, layers:)
        validate_layers(layers)
        FileUtils.mkdir_p(File.dirname(File.expand_path(output)))
        temporary = "#{output}.#{Process.pid}.tmp"
        write_package(temporary, descriptor, layers)
        File.rename(temporary, output)
      ensure
        FileUtils.rm_f(temporary) if temporary
      end

      private

      def write_package(temporary, descriptor, layers)
        File.open(temporary, "wb") do |package|
          File.open(descriptor, "rb") { |file| IO.copy_stream(file, package) }
          manifest = encode_manifest(layers.map { |layer| append_layer(package, layer) })
          package.write(manifest)
          package.write([manifest.bytesize].pack("Q<"))
          package.write(MAGIC)
        end
      end

      def append_layer(package, layer)
        offset = package.pos
        File.open(layer.path, "rb") { |file| IO.copy_stream(file, package) }
        [layer.mount_point, offset, package.pos - offset]
      end

      def encode_manifest(records)
        records.each_with_object([records.length].pack("L<")) do |(mount_point, offset, size), manifest|
          encoded_mount = mount_point.b
          manifest << [encoded_mount.bytesize].pack("S<")
          manifest << encoded_mount
          manifest << [offset, size].pack("Q<Q<")
        end
      end

      def validate_layers(layers)
        raise ArgumentError, "A layered package must contain at least one layer" if layers.empty?

        mount_points = layers.map(&:mount_point)
        raise ArgumentError, "Layer mount points must be unique" unless mount_points.uniq.length == mount_points.length

        layers.each { |layer| validate_layer(layer) }
      end

      def validate_layer(layer)
        raise ArgumentError, "Invalid layer mount point: #{layer.mount_point.inspect}" unless valid_mount?(layer)
        raise ArgumentError, "Layer image does not exist: #{layer.path}" unless File.file?(layer.path)
        return unless layer.mount_point.bytesize > 65_535

        raise ArgumentError, "Layer mount point is too long: #{layer.mount_point}"
      end

      def valid_mount?(layer)
        components = layer.mount_point.split("/")
        !layer.mount_point.empty? &&
          !layer.mount_point.start_with?("/") &&
          components.none? { |component| component.empty? || component == "." || component == ".." }
      end
    end
  end
end

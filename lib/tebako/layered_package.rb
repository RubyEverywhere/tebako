# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "fileutils"
require "digest"

require_relative "generated/layered_format"

# rubocop:disable Metrics
# Tebako - an executable packager
module Tebako
  # Writes application packages made from independently reusable DwarFS images.
  module LayeredPackage
    MAGIC = Tebako::Generated::LayeredFormat::MAGIC
    Layer = Struct.new(:mount_point, :path, keyword_init: true)
    InspectedLayer = Struct.new(:mount_point, :offset, :byte_size, :sha256, keyword_init: true)
    Inspection = Struct.new(:format, :major_version, :minor_version, :descriptor_size, :byte_size, :sha256, :layers,
                            keyword_init: true) do
      def to_h
        {
          "format" => format,
          "major_version" => major_version,
          "minor_version" => minor_version,
          "descriptor_size" => descriptor_size,
          "size" => byte_size,
          "sha256" => sha256,
          "layers" => layers.map do |layer|
            {
              "mount_point" => layer.mount_point,
              "offset" => layer.offset,
              "size" => layer.byte_size,
              "sha256" => layer.sha256
            }
          end
        }
      end
    end

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

      def inspect(path)
        inspect_bytes(File.binread(path))
      end

      def inspect_bytes(package)
        raise ArgumentError, "Package is too small for a layered footer" if package.bytesize < footer_size
        raise ArgumentError, "Package is not a supported layered package" unless package.end_with?(MAGIC)

        manifest_size = package.byteslice(-footer_size, 8).unpack1("Q<")
        footer_offset = package.bytesize - footer_size
        raise ArgumentError, "Invalid layer manifest size" if manifest_size > footer_offset

        manifest_offset = footer_offset - manifest_size
        layers = decode_manifest(package, manifest_offset, footer_offset)
        Inspection.new(
          format: "layered",
          major_version: Tebako::Generated::LayeredFormat::MAJOR_VERSION,
          minor_version: Tebako::Generated::LayeredFormat::MINOR_VERSION,
          descriptor_size: layers.map(&:offset).min,
          byte_size: package.bytesize,
          sha256: Digest::SHA256.hexdigest(package),
          layers: layers
        )
      end

      private

      def decode_manifest(package, manifest_offset, footer_offset)
        cursor = manifest_offset
        count, cursor = read_integer(package, cursor, 4, footer_offset)
        raise ArgumentError, "A layered package must contain at least one layer" if count.zero?
        raise ArgumentError, "Layer count is too large" if count > (footer_offset - cursor) / 19

        layers = count.times.map do
          mount_size, cursor = read_integer(package, cursor, 2, footer_offset)
          if mount_size.zero? || cursor + mount_size > footer_offset
            raise ArgumentError,
                  "Invalid layer mount point length"
          end

          mount_point = package.byteslice(cursor, mount_size)
          cursor += mount_size
          offset, cursor = read_integer(package, cursor, 8, footer_offset)
          size, cursor = read_integer(package, cursor, 8, footer_offset)
          validate_inspected_layer!(mount_point, offset, size, manifest_offset)
          payload = package.byteslice(offset, size)
          raise ArgumentError, "Invalid layer payload bounds" unless payload&.bytesize == size

          InspectedLayer.new(
            mount_point: mount_point,
            offset: offset,
            byte_size: size,
            sha256: Digest::SHA256.hexdigest(payload)
          )
        end
        raise ArgumentError, "Trailing layer manifest data" unless cursor == footer_offset

        validate_inspected_layers!(layers, manifest_offset)
        layers
      end

      def read_integer(package, cursor, bytes, limit)
        raise ArgumentError, "Truncated layer manifest" if cursor + bytes > limit

        format = { 2 => "S<", 4 => "L<", 8 => "Q<" }.fetch(bytes)
        [package.byteslice(cursor, bytes).unpack1(format), cursor + bytes]
      end

      def validate_inspected_layer!(mount_point, offset, size, manifest_offset)
        layer = Layer.new(mount_point: mount_point, path: nil)
        raise ArgumentError, "Invalid layer mount point: #{mount_point.inspect}" unless valid_mount?(layer)
        raise ArgumentError, "Layer payload must not be empty" if size.zero?
        raise ArgumentError, "Layer payload is too large" if size > 0xffff_ffff
        raise ArgumentError, "Layer payload offset is invalid" if offset >= manifest_offset
      end

      def validate_inspected_layers!(layers, manifest_offset)
        mounts = layers.map(&:mount_point)
        raise ArgumentError, "Layer mount points must be unique" unless mounts.uniq.length == mounts.length

        ranges = layers.sort_by(&:offset)
        ranges.each_with_index do |layer, index|
          raise ArgumentError, "Layer payload exceeds manifest" if layer.offset + layer.byte_size > manifest_offset
          next if index.zero?

          previous = ranges[index - 1]
          raise ArgumentError, "Layer payloads overlap" if layer.offset < previous.offset + previous.byte_size
        end
      end

      def footer_size
        Tebako::Generated::LayeredFormat::FOOTER_SIZE
      end

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
# rubocop:enable Metrics

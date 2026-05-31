#!/usr/bin/env ruby
# Wires sherpa-onnx + onnxruntime xcframeworks into the Xcode project and sets
# the Objective-C bridging header + header search paths for the C API.
require 'xcodeproj'

PROJECT_PATH = File.join(__dir__, 'Doc Narrator.xcodeproj')
APP_TARGET   = 'Doc Narrator'
XCFRAMEWORKS = %w[sherpa-onnx.xcframework onnxruntime.xcframework].freeze
BRIDGING_HDR = 'Doc Narrator/Doc Narrator-Bridging-Header.h'
HEADER_PATHS = [
  '$(inherited)',
  '$(SRCROOT)/sherpa-onnx.xcframework/ios-arm64/Headers',
  '$(SRCROOT)/sherpa-onnx.xcframework/ios-arm64_x86_64-simulator/Headers',
].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)
target  = project.targets.find { |t| t.name == APP_TARGET }
abort "Target '#{APP_TARGET}' not found" unless target

# Get or create a Frameworks group at the project root level
frameworks_group = project.main_group.find_subpath('Frameworks', true)

XCFRAMEWORKS.each do |fw_name|
  # Skip if already referenced
  already = project.objects.select { |o|
    o.is_a?(Xcodeproj::Project::Object::PBXFileReference) && o.path == fw_name
  }.any?
  if already
    puts "  skip (already in project): #{fw_name}"
    next
  end

  ref = frameworks_group.new_reference(fw_name, 'SOURCE_ROOT')
  ref.last_known_file_type = 'wrapper.xcframework'
  ref.name = fw_name

  target.frameworks_build_phase.add_file_reference(ref)
  puts "  added: #{fw_name}"
end

# Apply build settings to every configuration of the app target
target.build_configurations.each do |cfg|
  s = cfg.build_settings

  s['SWIFT_OBJC_BRIDGING_HEADER'] = BRIDGING_HDR

  existing = Array(s['HEADER_SEARCH_PATHS'])
  merged   = (existing + HEADER_PATHS).uniq
  s['HEADER_SEARCH_PATHS'] = merged

  puts "  config '#{cfg.name}': bridging header + header search paths set"
end

project.save
puts "\nDone — open Doc Narrator.xcodeproj and build."

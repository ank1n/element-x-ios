#!/usr/bin/env ruby

require 'xcodeproj'

# Paths
project_path = '/Users/ankin/Documents/element-x-fork/ios/ElementX.xcodeproj'

# Open project
project = Xcodeproj::Project.open(project_path)

# Find main target
target = project.targets.find { |t| t.name == 'ElementX' }
if target.nil?
  puts "Error: ElementX target not found"
  exit 1
end

# Find groups by path
def find_group_by_path(project, path)
  project.main_group.recursive_children.find do |child|
    child.is_a?(Xcodeproj::Project::Object::PBXGroup) && child.path == path
  end
end

# Find FlowCoordinators and Screens groups
flow_coordinators_group = find_group_by_path(project, 'FlowCoordinators')
screens_group = find_group_by_path(project, 'Screens')

if flow_coordinators_group.nil?
  puts "Error: FlowCoordinators group not found"
  exit 1
end

if screens_group.nil?
  puts "Error: Screens group not found"
  exit 1
end

puts "✅ Found FlowCoordinators and Screens groups"

# Helper function to add file to group and target
def add_file_to_project(group, filename, target)
  # Check if file already exists in project
  existing = group.files.find { |f| f.path == filename }
  if existing
    puts "⚠️  #{filename} already exists in project, skipping"
    return
  end

  file_ref = group.new_file(filename)
  target.add_file_references([file_ref])
  puts "✅ Added #{filename}"
end

# Add WidgetsTabFlowCoordinator.swift to FlowCoordinators
add_file_to_project(
  flow_coordinators_group,
  'WidgetsTabFlowCoordinator.swift',
  target
)

# Create WidgetsListScreen group
widgets_list_group = screens_group.new_group('WidgetsListScreen', 'WidgetsListScreen')
puts "✅ Created WidgetsListScreen group"

# Add WidgetsListScreen files
widgets_list_files = [
  'WidgetsListScreenCoordinator.swift',
  'WidgetsListScreenModels.swift',
  'WidgetsListScreenViewModel.swift',
  'WidgetsListScreen.swift'
]

widgets_list_files.each do |filename|
  add_file_to_project(widgets_list_group, filename, target)
end

# Create WidgetWebViewScreen group
widget_webview_group = screens_group.new_group('WidgetWebViewScreen', 'WidgetWebViewScreen')
puts "✅ Created WidgetWebViewScreen group"

# Add WidgetWebViewScreen files
widget_webview_files = [
  'WidgetWebViewScreenCoordinator.swift',
  'WidgetWebViewScreenModels.swift',
  'WidgetWebViewScreenViewModel.swift',
  'WidgetWebViewScreen.swift'
]

widget_webview_files.each do |filename|
  add_file_to_project(widget_webview_group, filename, target)
end

# Save project
project.save
puts "\n✅ Project saved successfully!"
puts "\n📋 Next steps:"
puts "1. Open ElementX.xcodeproj in Xcode"
puts "2. Clean build folder: Product → Clean Build Folder (⇧⌘K)"
puts "3. Build project: Product → Build (⌘B)"
puts "\n💡 Backup created at: ElementX.xcodeproj/project.pbxproj.backup"

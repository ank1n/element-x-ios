#!/usr/bin/env ruby

require 'xcodeproj'

project_path = 'ElementX.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Get main target
target = project.targets.find { |t| t.name == 'ElementX' }

# New files to add
new_files = [
  # Contacts
  'ElementX/Sources/FlowCoordinators/ContactsTabFlowCoordinator.swift',
  'ElementX/Sources/Screens/ContactsListScreen/ContactsListScreenModels.swift',
  'ElementX/Sources/Screens/ContactsListScreen/ContactsListScreenViewModel.swift',
  'ElementX/Sources/Screens/ContactsListScreen/ContactsListScreen.swift',
  'ElementX/Sources/Screens/ContactsListScreen/ContactsListScreenCoordinator.swift',
  # Calls
  'ElementX/Sources/FlowCoordinators/CallsTabFlowCoordinator.swift',
  'ElementX/Sources/Screens/CallsListScreen/CallsListScreenModels.swift',
  'ElementX/Sources/Screens/CallsListScreen/CallsListScreenViewModel.swift',
  'ElementX/Sources/Screens/CallsListScreen/CallsListScreen.swift',
  'ElementX/Sources/Screens/CallsListScreen/CallsListScreenCoordinator.swift',
]

# Find or create groups
def find_or_create_group(project, path)
  parts = path.split('/')
  current_group = project.main_group
  
  parts[0...-1].each do |part|
    found = current_group.groups.find { |g| g.name == part || g.path == part }
    if found
      current_group = found
    else
      current_group = current_group.new_group(part, part)
    end
  end
  
  current_group
end

new_files.each do |file_path|
  next unless File.exist?(file_path)
  
  # Check if already in project
  existing = project.files.find { |f| f.path == file_path || f.real_path.to_s.end_with?(File.basename(file_path)) }
  if existing
    puts "Already exists: #{file_path}"
    next
  end
  
  group = find_or_create_group(project, file_path)
  file_ref = group.new_reference(File.basename(file_path))
  file_ref.set_last_known_file_type('sourcecode.swift')
  
  target.source_build_phase.add_file_reference(file_ref)
  puts "Added: #{file_path}"
end

project.save
puts "Done!"

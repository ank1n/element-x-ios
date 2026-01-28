#!/usr/bin/env ruby

require 'xcodeproj'

project_path = '/Users/ankin/Documents/element-x-fork/ios/ElementX.xcodeproj'
project = Xcodeproj::Project.open(project_path)

puts "=== Main Group Info ==="
puts "Name: #{project.main_group.name.inspect}"
puts "Path: #{project.main_group.path.inspect}"
puts "\n=== Top Level Groups ==="

def print_group(group, indent = 0)
  prefix = "  " * indent
  puts "#{prefix}📁 #{group.name.inspect} (path: #{group.path.inspect})"

  group.groups.each do |subgroup|
    print_group(subgroup, indent + 1)
  end

  if indent < 2
    group.files.take(3).each do |file|
      puts "#{prefix}  📄 #{file.name}"
    end
    if group.files.count > 3
      puts "#{prefix}  ... and #{group.files.count - 3} more files"
    end
  end
end

print_group(project.main_group)

puts "\n=== Looking for ElementX or Sources ==="
project.main_group.recursive_children.select { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) }.each do |group|
  if group.name =~ /ElementX|Sources|FlowCoordinator/i || group.path =~ /ElementX|Sources|FlowCoordinator/i
    puts "Found: #{group.name.inspect} at path #{group.path.inspect}"
  end
end

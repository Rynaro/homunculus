#!/usr/bin/env ruby
# frozen_string_literal: true

# Reads fleet JSON from stdin and installed JSON from file (ENV["INSTALLED_JSON"]).
# Prints Homunculus Model Store table and footer. Used by bin/ollama list.

require "json"

fleet = JSON.parse($stdin.read)
installed_path = ENV["INSTALLED_JSON"]
installed = if installed_path && File.file?(installed_path)
  data = JSON.parse(File.read(installed_path))
  (data["models"] || []).each_with_object({}) { |m, h| h[m["name"]] = m["size"].to_i }
else
  {}
end

def format_size(bytes)
  return "0 B" if bytes.nil? || bytes <= 0
  gb = bytes / (1024.0**3)
  return "#{(bytes / (1024.0**2)).round(0)} MB" if gb < 1
  "#{gb.round(1)} GB"
end

puts "  Tier        Model                 Description                    Status"
puts "  ──────────  ────────────────────  ─────────────────────────────  ──────────"

installed_count = 0
total_bytes = 0

fleet.each do |entry|
  tier = entry["tier"]
  model = entry["model"]
  desc = (entry["description"] || "").slice(0, 30)
  size = installed[model]
  if size
    installed_count += 1
    total_bytes += size
    status = "✓ Installed (#{format_size(size)})"
  else
    status = "✗ Missing"
  end
  printf "  %-10s  %-20s  %-30s  %s\n", tier, model, desc, status
end

puts ""
puts "  Fleet: #{installed_count}/#{fleet.size} installed · #{format_size(total_bytes)} used"
puts ""
puts "  Pull missing: bin/ollama pull --all"

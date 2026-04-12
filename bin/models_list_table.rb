#!/usr/bin/env ruby
# frozen_string_literal: true

# Reads fleet JSON from stdin (from models_fleet_parser.rb).
# ENV["OLLAMA_INSTALLED_JSON"] — path to Ollama /api/tags JSON (may be absent/empty).
# ENV["LLAMACPP_MODELS_JSON"]  — path to llama.cpp /v1/models JSON (may be absent/empty).
# Prints the unified multi-driver model table.

require "json"

fleet = JSON.parse($stdin.read)

# Parse Ollama installed models: name => size_bytes
ollama_path = ENV.fetch("OLLAMA_INSTALLED_JSON", nil)
ollama_installed = if ollama_path && File.file?(ollama_path)
                     data = JSON.parse(File.read(ollama_path))
                     (data["models"] || []).to_h { |m| [m["name"], m["size"].to_i] }
                   else
                     {}
                   end

# Parse llama.cpp loaded models: id => true
llamacpp_path = ENV.fetch("LLAMACPP_MODELS_JSON", nil)
llamacpp_loaded = if llamacpp_path && File.file?(llamacpp_path)
                    data = JSON.parse(File.read(llamacpp_path))
                    (data["data"] || []).to_h { |m| [m["id"].to_s, true] }
                  else
                    {}
                  end

def format_size(bytes)
  return nil if bytes.nil? || bytes <= 0

  gb = bytes / (1024.0**3)
  return "#{(bytes / (1024.0**2)).round(0)} MB" if gb < 1

  "#{gb.round(1)} GB"
end

DRIVER_LABEL = { "ollama" => "ollama", "llamacpp" => "llama.cpp" }.freeze

puts "  Tier        Driver      Model                 Description                    Status"
puts "  ──────────  ──────────  ────────────────────  ─────────────────────────────  ──────────────────────"

installed_count = 0
total_bytes = 0

fleet.each do |entry|
  tier   = entry["tier"]
  model  = entry["model"]
  driver = entry["driver"]
  desc   = (entry["description"] || "").slice(0, 30)

  driver_label = DRIVER_LABEL.fetch(driver, driver)

  status = case driver
           when "ollama"
             size = ollama_installed[model] || ollama_installed["#{model}:latest"]
             if size
               installed_count += 1
               total_bytes += size
               human = format_size(size)
               "installed (#{human})"
             elsif ollama_installed.empty?
               "unknown (ollama unreachable)"
             else
               "missing"
             end
           when "llamacpp"
             # Match by basename of path or exact model id
             basename = File.basename(model.to_s, ".*")
             matched = llamacpp_loaded.any? { |id, _| id == model || id.include?(basename) }
             if matched
               installed_count += 1
               "loaded"
             elsif llamacpp_loaded.empty? && !llamacpp_path
               "unknown (server unreachable)"
             elsif llamacpp_loaded.empty?
               "not loaded"
             else
               "not loaded"
             end
           else
             "unknown"
           end

  printf "  %-10<tier>s  %-10<driver>s  %-20<model>s  %-30<desc>s  %<status>s\n",
         tier: tier, driver: driver_label, model: model, desc: desc, status: status
end

puts ""
puts "  Fleet: #{installed_count}/#{fleet.size} locally managed"
puts "  Total disk: #{format_size(total_bytes) || "0 B"}" if total_bytes.positive?
puts ""
puts "  Pull missing Ollama models : bin/models pull --all"
puts "  llama.cpp models           : bin/models pull <tier>  (prints instructions)"

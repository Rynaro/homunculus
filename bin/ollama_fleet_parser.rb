#!/usr/bin/env ruby
# frozen_string_literal: true

# Outputs JSON array of fleet tiers: [{ "tier", "model", "description" }].
# Reads config/models.toml (Ollama tiers only) and config/default.toml (embedding_model).
# Invoked by bin/ollama. Set MODELS_TOML and DEFAULT_TOML for paths (default: config/...).

require "toml-rb"
require "json"

models_path = ENV.fetch("MODELS_TOML", "config/models.toml")
default_path = ENV.fetch("DEFAULT_TOML", "config/default.toml")

models = TomlRB.parse(File.read(models_path))
default_cfg = TomlRB.parse(File.read(default_path))

fleet = []
(models["tiers"] || {}).each do |tier_name, tier_hash|
  next unless tier_hash.is_a?(Hash) && tier_hash["provider"] == "ollama"

  fleet << {
    "tier" => tier_name,
    "model" => tier_hash["model"].to_s,
    "description" => (tier_hash["description"] || "").to_s
  }
end

embedding = default_cfg.dig("memory", "embedding_model")
if embedding && !embedding.to_s.empty?
  fleet << {
    "tier" => "embedding",
    "model" => embedding.to_s,
    "description" => "Memory embeddings"
  }
end

puts fleet.to_json

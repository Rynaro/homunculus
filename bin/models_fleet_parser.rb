#!/usr/bin/env ruby
# frozen_string_literal: true

# Outputs JSON array of ALL fleet tiers including driver info:
# [{ "tier", "model", "driver", "description" }]
# Reads config/models.toml for tiers and config/default.toml for embedding_model.
# driver: "ollama" | "llamacpp" | "anthropic"
# Invoked by bin/models. Set MODELS_TOML and DEFAULT_TOML for paths (default: config/...).

require "toml-rb"
require "json"

models_path = ENV.fetch("MODELS_TOML", "config/models.toml")
default_path = ENV.fetch("DEFAULT_TOML", "config/default.toml")

models = TomlRB.parse(File.read(models_path))
default_cfg = TomlRB.parse(File.read(default_path))

fleet = []
(models["tiers"] || {}).each do |tier_name, tier_hash|
  next unless tier_hash.is_a?(Hash)

  driver = tier_hash["provider"].to_s
  next if driver == "anthropic" # cloud tiers: not locally managed

  fleet << {
    "tier" => tier_name,
    "model" => tier_hash["model"].to_s,
    "driver" => driver,
    "description" => (tier_hash["description"] || "").to_s
  }
end

embedding = default_cfg.dig("memory", "embedding_model")
if embedding && !embedding.to_s.empty?
  fleet << {
    "tier" => "embedding",
    "model" => embedding.to_s,
    "driver" => "ollama",
    "description" => "Memory embeddings"
  }
end

puts fleet.to_json

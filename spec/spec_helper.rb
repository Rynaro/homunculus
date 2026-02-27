# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
  add_filter "/config/"
  add_filter "/vendor/"

  add_group "Agent", "lib/homunculus/agent"
  add_group "Tools", "lib/homunculus/tools"
  add_group "Memory", "lib/homunculus/memory"
  add_group "Security", "lib/homunculus/security"
  add_group "Interfaces", "lib/homunculus/interfaces"
  add_group "Scheduler", "lib/homunculus/scheduler"
  add_group "Skills", "lib/homunculus/skills"

  # Raise these thresholds as coverage improves
  minimum_coverage 75
  minimum_coverage_by_file 30
end

require "bundler/setup"
require "dotenv"
# Overload .env.test first so test-specific values (e.g. ESCALATION_ENABLED=true)
# take precedence over any values already set by the container env or .env.
# Then load .env (non-overwriting) to pick up any keys not set in .env.test.
Dotenv.overload(".env.test")
Dotenv.load(".env")

# Suppress logging during tests
require "semantic_logger"
SemanticLogger.default_level = :fatal

require_relative "../lib/homunculus/version"
require_relative "../lib/homunculus/utils/logging"
require_relative "../lib/homunculus/config"
require_relative "../lib/homunculus/session"
require_relative "../lib/homunculus/security/audit"
require_relative "../lib/homunculus/security/sandbox"
require_relative "../lib/homunculus/tools/base"
require_relative "../lib/homunculus/tools/registry"
require_relative "../lib/homunculus/tools/echo"
require_relative "../lib/homunculus/tools/datetime_now"
require_relative "../lib/homunculus/tools/workspace_read"
require_relative "../lib/homunculus/tools/workspace_write"
require_relative "../lib/homunculus/tools/workspace_delete"
require_relative "../lib/homunculus/tools/workspace_list"
require_relative "../lib/homunculus/tools/memory_search"
require_relative "../lib/homunculus/tools/memory_save"
require_relative "../lib/homunculus/tools/memory_daily_log"
require_relative "../lib/homunculus/tools/memory_curate"
require_relative "../lib/homunculus/tools/files"
require_relative "../lib/homunculus/tools/shell"
require_relative "../lib/homunculus/tools/web_session_store"
require_relative "../lib/homunculus/tools/web"
require_relative "../lib/homunculus/tools/web_extract"
require_relative "../lib/homunculus/security/content_sanitizer"
require_relative "../lib/homunculus/security/threat_patterns"
require_relative "../lib/homunculus/security/skill_validator"
require_relative "../lib/homunculus/tools/mqtt"
require_relative "../lib/homunculus/tools/scheduler"
require_relative "../lib/homunculus/memory/indexer"
require_relative "../lib/homunculus/memory/embedder"
require_relative "../lib/homunculus/memory/store"
require_relative "../lib/homunculus/agent/context/token_counter"
require_relative "../lib/homunculus/agent/context/budget"
require_relative "../lib/homunculus/agent/context/compressor"
require_relative "../lib/homunculus/agent/context/window"
require_relative "../lib/homunculus/agent/models"
require_relative "../lib/homunculus/agent/prompt"
require_relative "../lib/homunculus/agent/budget"
require_relative "../lib/homunculus/agent/router"
require_relative "../lib/homunculus/agent/loop"
require_relative "../lib/homunculus/agent/agent_definition"
require_relative "../lib/homunculus/agent/agent_worker"
require_relative "../lib/homunculus/agent/multi_agent_manager"
require_relative "../lib/homunculus/skills/skill"
require_relative "../lib/homunculus/skills/loader"
require_relative "../lib/homunculus/scheduler/job_store"
require_relative "../lib/homunculus/scheduler/notification"
require_relative "../lib/homunculus/scheduler/manager"
require_relative "../lib/homunculus/scheduler/heartbeat"
require_relative "../lib/homunculus/interfaces/telegram"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end

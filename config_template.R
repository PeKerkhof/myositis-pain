# config_template.R
# TEMPLATE FILE - Copy this to 'config.R' and update paths for your system
# DO NOT edit this template directly

# Path to reddit data hub
# Update this to point to your local reddit-data-hub location
REDDIT_DATA_PATH <- "/path/to/your/reddit-data-hub"

# Path to project data (data, LLM output, paper folders)
# Update this to point to your local project data location
DATA_PATH <- "/path/to/your/myositis-pain-data"

# Example usage in your scripts:
# source(here::here("config.R"))
# data <- read_feather(file.path(REDDIT_DATA_PATH, "queries/query-output/myositis_submissions_20250910.feather"))
# data <- read_feather(file.path(DATA_PATH, "data/myositis_submissions.feather"))
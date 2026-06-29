# VisionX Update Utility

VisionX Update Utility is a field-team updater for maintaining a VisionX production installation from one guided script: it helps apply the latest application image changes, update supporting services, refresh Mirth integration behavior, apply required database updates, and run selected production cleanup tools when needed. The public repository does not include production credentials or site-specific configuration; the dev team must provide the private `config.local.env` separately, then the operator runs `chmod 600 config.local.env` and `./run.sh`.

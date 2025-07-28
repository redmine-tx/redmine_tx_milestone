# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Redmine plugin called "Redmine Tx Milestone" that adds milestone management functionality to Redmine. It's written in Ruby and follows the standard Redmine plugin structure.

## Development Environment

This plugin is designed to run within a Redmine environment. The standard development workflow involves:

1. **Testing**: Run tests using standard Rails testing commands from the Redmine root directory:
   ```bash
   cd /var/www/redmine-dev
   bundle exec rake test:plugins:redmine_tx_milestone
   ```

2. **Development Server**: Start the Redmine development server from the Redmine root:
   ```bash
   cd /var/www/redmine-dev
   bundle exec rails server
   ```

## Architecture

### Core Components

1. **MilestoneController** (`app/controllers/milestone_controller.rb`):
   - Main controller handling milestone functionality
   - Key actions: `index`, `gantt`, `roadmap`, `tetris` (auto-scheduling), `tools`
   - Handles roadmap data saving/loading and issue auto-scheduling

2. **RoadmapData Model** (`app/models/roadmap_data.rb`):
   - Stores JSON roadmap data per project
   - Provides methods for accessing categories and metadata
   - Handles active roadmap retrieval

3. **Helper Modules**:
   - `RedmineTxMilestoneHelper`: UI helpers, version color coding, issue rendering
   - `RedmineTxMilestoneAutoScheduleHelper`: Core auto-scheduling logic with topological sorting

### Key Features

- **Milestone Management**: Visual milestone tracking with configurable deadline warnings
- **Auto-scheduling**: Tetris-style issue scheduling considering dependencies and resource constraints
- **Roadmap Visualization**: Interactive roadmap with categories, events, and schedules
- **Gantt Charts**: Enhanced Gantt chart views for project visualization
- **Issue Relations**: Handles precedence/blocking relationships between issues

### Plugin Integration

The plugin extends core Redmine classes:
- `Version` model gets `marks` method for milestone visualization
- `Issue` model gets auto-scheduling capabilities
- `IssueRelation` model behavior can be overridden based on settings

### Routes Structure

Routes are defined in `config/routes.rb` with nested project resources:
- `/projects/:project_id/milestone/` - Main milestone views
- `/projects/:project_id/milestone/gantt` - Gantt chart views
- `/projects/:project_id/milestone/tetris` - Auto-scheduling interface
- `/projects/:project_id/milestone/roadmap` - Roadmap visualization
- `/projects/:project_id/milestone/tools` - Administrative tools

### Settings and Configuration

Plugin settings are managed through Redmine's plugin settings system:
- Milestone deadline warnings (1-5 configurable periods)
- Auto-scheduling behavior toggles
- Dependencies on other TX plugins (`redmine_tx_0_base`, `redmine_tx_advanced_issue_status`, etc.)

### Database

The plugin includes migration `001_create_roadmap_data.rb` to create the `roadmap_data` table for storing JSON roadmap configurations.

## Dependencies

This plugin requires several other TX plugins:
- `redmine_tx_0_base` (>= 0.0.1)
- `redmine_tx_advanced_issue_status` (>= 0.0.1) 
- `redmine_tx_advanced_tracker` (>= 0.0.1)

## Views and UI

The plugin provides extensive UI components:
- Milestone overview and detail views
- Interactive Gantt charts with styling
- Auto-scheduling interfaces for users and issues
- Roadmap visualization with drag-and-drop functionality
- Administrative tools for validation and synchronization
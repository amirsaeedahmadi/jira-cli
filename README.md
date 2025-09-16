# Jira CLI

A lightweight and flexible **command-line interface for Jira** that allows you to manage issues, projects, and workflows directly from your terminal.  
This tool integrates with any Jira instance (Cloud or Server) and supports authentication via token or username/password.  

---

## Features

- **Authentication** using Bearer token or Basic Auth.  
- **List issues** by project, assignee, status, or JQL.  
- **Log work** directly to issues from the CLI.  
- **Create and update issues** without leaving your terminal.  
- **Customizable output** (status, type, summary, updated time, etc.).  
- **Config file support** for storing Jira instance URL and credentials.  
- Works with **any Jira instance** (Server or Cloud).  

---

## Installation

Clone the repository and make the script executable:

```bash
git clone https://github.com/amirsaeedahmadi/jira-cli.git
cd jira-cli
chmod +x jira-cli.sh
```

(Optional) Add it to your `$PATH` for global usage:

```bash
sudo ln -s $(pwd)/jira-cli.sh /usr/local/bin/jira
```

Now you can run commands with:

```bash
jira list
jira worklog ISSUE-123 --time "2h"
```

---

## Configuration

Before using the CLI, create a config file with your Jira details.  
Supported locations (checked in order):

- `./.jira-cli.conf`  
- `~/.jira-cli.conf`  

### Example `.jira-cli.conf`

```bash
# REQUIRED
JIRA_URL="https://your-jira-instance.com"

# Choose ONE authentication method:

# 1) Bearer token
# JIRA_TOKEN="your-personal-access-token"

# 2) Basic auth
# JIRA_USER="your-username"
# JIRA_PASS="your-password"

# Optional settings
# JIRA_CURL_OPTS="-k"   # Ignore SSL issues
# JIRA_DEBUG=1          # Enable debug mode
```

---

## Usage

### List Issues

```bash
jira list --project PRJ
```

Example output:

```
KEY       TYPE      STATUS     UPDATED              SUMMARY
PRJ-584   Task      To Do      2025-09-15 12:19:02  Split service issue type
PRJ-583   Bug       To Do      2025-09-15 12:19:02  Security fix for iframe issue
```

### Create Issue

```bash
jira create --project PRJ --type Task --summary "New feature request" --description "Details of the request"
```

### Log Work

```bash
jira worklog PRJ-123 --time "45m" --comment "Investigated issue"
```

### Run JQL

```bash
jira jql "assignee = currentUser() AND status = 'In Progress'"
```

---

## Demo

Here’s how it looks in action:

![Jira CLI Demo](docs/demo.gif)

*(Replace `docs/demo.gif` with your actual screenshot or GIF path)*

---

## Development

To contribute or extend:

```bash
git clone https://github.com/amirsaeedahmadi/jira-cli.git
cd jira-cli
# hack on jira-cli.sh
```

---

## License

This project is licensed under the **MIT License** – see the [LICENSE](LICENSE) file for details.

---


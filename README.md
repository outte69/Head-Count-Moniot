# Visitor Island Monitor Web App

This app can now run in two ways:

- `Local network mode` for your office or island network
- `Hosted web app mode` for access from anywhere

The dashboard, data entry form, reports, month filter, date filter, and CSV export are the same in both modes.

## Project Files

- `app.rb` contains the reusable app logic and API
- `server.rb` starts the simple local WEBrick server
- `config.ru` is the hosted Rack entrypoint
- `config/puma.rb` runs the app on a hosted Puma server
- `Gemfile` lists the Ruby gems needed for hosting
- `Procfile` gives many hosts a default web start command
- `visitor_island_monitor.sqlite3` is the main hosted database
- `records.json`, `users.json`, and `audit_log.json` are now only legacy import sources if they already exist
- `public/index.html` is the browser dashboard used by every user

## Local Network Use

On Windows, you can simply double-click:

```text
start-server.bat
```

For background use on Windows:

```text
start-background-server.bat
```

For Windows without Ruby:

```text
start-server-no-ruby.bat
```

For Windows background use without Ruby:

```text
start-background-no-ruby.bat
```

For Windows office network sharing without Ruby:

```text
start-server-no-ruby-network.bat
```

For Windows office network background sharing without Ruby:

```text
start-background-no-ruby-network.bat
```

For the fixed office IP `10.100.10.254` without Ruby:

```text
start-server-no-ruby-10.100.10.254.bat
```

For fixed office IP background mode:

```text
start-background-no-ruby-10.100.10.254.bat
```

For the simplest one-computer version with no server setup:

```text
start-standalone-local.bat
```

On macOS, you can double-click:

```text
start-server.command
```

For background use on macOS:

```text
install-background-server.command
```

Or run manually:

```sh
ruby ./server.rb
```

Then open:

```text
http://localhost:4567
```

Other computers on the same network should open:

```text
http://HOST-IP-ADDRESS:4567
```

## Hosted Web App Use

This version is now structured so it can be deployed to a Ruby host such as a VPS, Render, Railway, or Fly.io.

Typical setup:

```sh
bundle install
bundle exec puma -C config/puma.rb
```

Or with Rack:

```sh
bundle exec rackup config.ru -p 4567
```

For Railway, if automatic Railpack detection fails, this repo now includes:

- `Dockerfile`
- `start.sh`

Railway can deploy it directly with Docker instead of trying to guess the build plan.

Important environment values:

- `PORT` sets the web port
- `DATA_FILE` lets you move the shared data file to another folder
- `DATABASE_PATH` lets you choose where the SQLite database file is stored
- `APP_ENV` sets the runtime environment
- `WHATSAPP_SUMMARY_ENABLED=true` turns on automatic hourly WhatsApp summaries
- `WHATSAPP_ACCESS_TOKEN` is your Meta WhatsApp Cloud API token
- `WHATSAPP_PHONE_NUMBER_ID` is your WhatsApp sender phone number ID
- `WHATSAPP_RECIPIENTS` is a comma-separated list of named recipients in `Name:+number` format
- `WHATSAPP_TEMPLATE_NAME` is required for scheduled WhatsApp summaries
- `WHATSAPP_TEMPLATE_LANGUAGE` defaults to `en_US`

Recommended Railway settings:

- Builder: `Dockerfile`
- Start command: leave blank if using Dockerfile
- Volume mount path: `/app/data`
- Environment variable: `DATABASE_PATH=/app/data/visitor_island_monitor.sqlite3`

## WhatsApp Summary

The hosted app can now send an automatic summary every hour when WhatsApp settings are present.

What it sends:

- duty date
- visitor arrivals
- visitor departures
- visitors remaining
- event visitor arrivals
- event visitor departures
- event visitors remaining
- staff arrivals
- staff departures
- staff remaining

How it works:

- it checks once a minute
- it sends once per hour
- it tracks the last sent hour in `visitor_monitor_state.json` beside the database so it does not resend the same hour after a restart
- it uses the current operational duty date, which still runs from `06:00` to the next day `05:59`

Message mode:

- scheduled summaries use an approved WhatsApp template
- the template should accept one body placeholder because the app sends the whole formatted summary as a single text variable

Example Railway variables:

```text
WHATSAPP_SUMMARY_ENABLED=true
WHATSAPP_ACCESS_TOKEN=your-meta-token
WHATSAPP_PHONE_NUMBER_ID=your-phone-number-id
WHATSAPP_RECIPIENTS=Supervisor:+9607744490,Manager:+9607000000
WHATSAPP_TEMPLATE_NAME=visitor_hourly_summary
WHATSAPP_TEMPLATE_LANGUAGE=en_US
```

## Login Users

On first start, the app creates a default admin user in `users.json`:

- Username: `Supervisor`
- Password: `Cross@119`

Sign in with that account first, then create the rest of your users inside the dashboard.

Permissions:

- `Admin` users can create users, export data, and delete wrong entries
- `User` accounts can sign in, enter records, and edit records

Audit history:

- Admin users can see a dashboard audit log
- The app records user creation, record creation, record edits, and record deletions

## Source Protection

In a hosted setup, these parts stay on the server and are not shared as project files with users:

- login and admin permission rules
- user storage
- record storage
- audit logging
- CSV export generation

This means users do not receive the Ruby backend code just by using the app in a browser.

Important limit:

- the browser interface itself still has to be sent to the user, so HTML, CSS, and JavaScript cannot be made completely invisible in any normal web app
- to protect the app better, keep the project folder only on the server and give users only the web address

## Data Storage Note

The hosted app now uses a SQLite database file named `visitor_island_monitor.sqlite3`.

On first run, if older `records.json`, `users.json`, or `audit_log.json` files exist, the app can import that data into the database.

SQLite is a real database and is a much better fit than flat JSON files for a private hosted deployment on one server.

If you plan to use:

- many users at once
- automatic replication
- multiple hosted instances
- larger-scale deployment

the next step after this would be PostgreSQL.

## Windows Notes

- Keep the Command Prompt window open while the local server is in use
- If Windows Firewall asks for permission, allow access on your private network
- `start-server.bat` now opens `http://localhost:4567` automatically
- `start-background-server.bat` starts the server in the background so other systems can keep using it after the launcher closes
- `stop-background-server.bat` stops the Windows background server
- `start-server-no-ruby.bat` runs the shared app with built-in PowerShell instead of Ruby
- `start-server-no-ruby.bat` uses localhost only and avoids the Windows access-denied URL reservation problem
- `start-server-no-ruby-network.bat` is for office sharing on the network and may need IT approval
- `start-background-no-ruby.bat` keeps the localhost-only PowerShell version running in the background
- `start-background-no-ruby-network.bat` keeps the office network PowerShell version running in the background
- `start-server-no-ruby-10.100.10.254.bat` binds the server to the fixed office IP `10.100.10.254`
- `start-background-no-ruby-10.100.10.254.bat` runs the fixed-IP version in the background
- `stop-background-no-ruby.bat` stops the PowerShell background server
- `start-standalone-local.bat` opens the standalone local app directly and avoids server startup problems
- If `start-server.bat` says Ruby is missing, install Ruby for Windows and make sure it is added to PATH

## macOS Notes

- Keep the Terminal window open while the local server is in use
- `start-server.command` opens `http://localhost:4567` automatically
- `install-background-server.command` installs and starts a LaunchAgent background service
- `stop-background-server.command` stops the macOS background service
- `remove-background-server.command` removes the background service
- If macOS warns about opening the launcher, right-click it and choose `Open`
- If the launcher says Ruby is missing, install Ruby and run it again

## Important

- Everyone must open the app through the server URL, not by opening the HTML file directly
- All users connected to the same running server will see the same live records
- For shared use from another system, the host computer must stay powered on and connected to the network
- With the background launchers, you do not need to keep the launcher window open
- For hosted use, back up your `visitor_island_monitor.sqlite3` file regularly

## Office Network Without Ruby

For a Windows office setup with IT restrictions, the easiest no-Ruby option is the included PowerShell server:

- `server.ps1`
- `start-server-no-ruby.bat`
- `start-server-no-ruby-network.bat`
- `start-background-no-ruby.bat`
- `start-background-no-ruby-network.bat`
- `start-server-no-ruby-10.100.10.254.bat`
- `start-background-no-ruby-10.100.10.254.bat`

This keeps the same browser app, shared records, users, admin permissions, and audit log structure, but runs on Windows without installing Ruby.

If Windows shows `HttpListenerException` or `Access is denied`, use the localhost-only launcher first. For office network sharing, IT may need to run a URL reservation such as:

```text
netsh http add urlacl url=http://+:4567/ user=YOUR-WINDOWS-USERNAME
```

If you only need one-computer use and want the least chance of startup errors, use the standalone local launcher instead of a server.

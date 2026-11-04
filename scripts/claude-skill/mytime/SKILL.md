---
name: mytime
description: Log a short label for the work done in this repo (this session, or today's commits) to MyTime, the user's time tracker, so it is added to that day's measured time for review. Use when the user says "log this to MyTime", "add this to my timesheet", "track this time", "/mytime", or asks to record or estimate time spent on a session or project.
argument-hint: "[label] [minutes]"
---

# Log work to MyTime

MyTime already measures how long Claude Code works in each repo, through hooks, and reads the user's commits in
linked repos. You add the **label**: a
1–3 word name for the work, which becomes the time entry's note and **appears on the client's invoice**.
MyTime merges a day's labels for a project into one suggestion. The user reviews it in MyTime › Review before
anything reaches the timesheet.

## Steps

1. **Find what was worked on** (skip this if the user gave a label):
   - If this session did work in the repo, use that.
   - If it didn't (for example `/mytime` run as an end-of-day step in a fresh session), look at today's work
     in the repo instead: your commits since midnight on every branch, plus anything not yet committed.

     ```bash
     git log --all --no-merges --since=midnight --author="$(git config user.email)" --format='%s'
     git status --short
     ```

     If that finds nothing either, ask the user what the work was. Don't invent a label.
2. **Choose the label**:
   - Use 1–3 words, Title-case the first word, and name the deliverable the client would recognise.
     Good: "Invoice layout", "Review tab", "Login fixes", "Stripe checkout".
     Bad: "Refactored ActivityTracker.swift", "Misc", "Claude session", ticket numbers, file names.
   - If you're continuing work this session already logged, reuse the same label, so it merges rather than
     adding a second one.
   - If the session covered clearly separate deliverables, log each one (at most 3).
3. **Run the command from the repo folder** (the folder decides the project):

   ```bash
   "$HOME/Library/Application Support/MyTime/Hooks/activity-hook.sh" log "<label>"
   ```

4. **Only add minutes when MyTime couldn't measure the time.** Examples: the work happened outside Claude Code,
   such as in a meeting or claude.ai chat, or the user tells you how long it took. Then pass a whole number of
   minutes as the third argument, e.g. `log "Planning call" 30`. Don't guess this session's length, or time from
   commits: you can't see a clock, and MyTime measures both.
5. **Tell the user in one line** what you logged, and that it's waiting in MyTime › Review.

If the command says it couldn't write to the inbox, or the script is missing, MyTime isn't installed on this
Mac. Say so, and don't retry.

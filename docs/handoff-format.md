# Handoff Format

Each offload should create a task packet before Claude Code starts.

## Required Fields

- Task name
- Objective
- Working directory
- Files or directories Claude may edit
- Files or directories Claude must not edit
- Constraints
- Expected deliverables
- Completion report format

## Completion Report

Claude should end each task by writing a concise report that includes:

- What changed
- Files changed
- Commands run
- Tests or checks performed
- Open questions or known issues


# CLAUDE.md

This file provides guidance for AI assistants working with this repository.

## Repository Overview

This is the **GitHub Skills: Introduction to GitHub** course — a template repository that teaches learners the fundamentals of GitHub through automated, step-by-step hands-on activities. It has no application source code; the "product" is the course itself, driven by GitHub Actions workflows.

## Repository Structure

```
skills-introduction-to-github/
├── README.md                        # Learner-facing course content (dynamically updated)
├── CLAUDE.md                        # This file
├── LICENSE                          # MIT license
├── .gitignore                       # Standard gitignore (compiled files, packages, OS files)
├── images/                          # Screenshots embedded in course instructions
│   ├── code-tab.png
│   ├── main-branch-dropdown.png
│   ├── create-branch-button.png
│   ├── create-new-file.png
│   ├── commit-full-screen.png
│   ├── compare-and-pull-request.png
│   ├── pull-request-branches.png
│   ├── Pull-request-description.png
│   ├── Actions-to-step-4.png
│   ├── Green-merge-pull-request.png
│   ├── delete-branch.png
│   ├── my-profile-file.png
│   ├── create-new-repository.png
│   └── profile-readme-example.png
└── .github/
    ├── dependabot.yml               # Monthly GitHub Actions dependency updates
    ├── steps/
    │   ├── -step.txt                # Current step counter (single integer: 0–4 or X)
    │   ├── 0-welcome.md             # Step 0 README content (placeholder)
    │   ├── 1-create-a-branch.md     # Step 1 README content
    │   ├── 2-commit-a-file.md       # Step 2 README content
    │   ├── 3-open-a-pull-request.md # Step 3 README content
    │   ├── 4-merge-your-pull-request.md # Step 4 README content
    │   └── X-finish.md              # Completion README content
    └── workflows/
        ├── 0-welcome.yml            # Triggered on push to main (step 0 → 1)
        ├── 1-create-a-branch.yml    # Triggered on branch creation (step 1 → 2)
        ├── 2-commit-a-file.yml      # Triggered on push to my-first-branch (step 2 → 3)
        ├── 3-open-a-pull-request.yml # Triggered on PR open (step 3 → 4)
        └── 4-merge-your-pull-request.yml # Triggered on push to main (step 4 → X)
```

## How the Course Works

### Step Tracking

The file `.github/steps/-step.txt` contains a single integer (0, 1, 2, 3, 4, or X) representing the learner's current step. Each workflow reads this file to determine whether it should run:

```yaml
- id: get_step
  run: |
    echo "current_step=$(cat ./.github/steps/-step.txt)" >> $GITHUB_OUTPUT
```

### Step Progression

Each workflow advances the course by one step using the `skills/action-update-step@v2` action, which updates both `-step.txt` and `README.md` with the content from the appropriate `.github/steps/` file:

```yaml
- name: Update to step N
  uses: skills/action-update-step@v2
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    from_step: N
    to_step: N+1
    branch_name: my-first-branch
```

### Course Flow

| Step | Trigger Event | Learner Action | Outcome |
|------|--------------|----------------|---------|
| 0 → 1 | `push` to `main` | Creates repository from template | README shows Step 1 instructions |
| 1 → 2 | `create` (branch/tag) | Creates branch named `my-first-branch` | README shows Step 2 instructions |
| 2 → 3 | `push` to `my-first-branch` | Commits a file to `my-first-branch` | README shows Step 3 instructions |
| 3 → 4 | `pull_request` (opened/reopened) | Opens PR from `my-first-branch` | README shows Step 4 instructions |
| 4 → X | `push` to `main` | Merges the pull request | README shows completion/finish content |

### Critical Branch Name

The branch name `my-first-branch` is **hardcoded** throughout all workflows. It must match exactly for the course automation to work:
- Step 1 workflow: checks `github.ref_name == 'my-first-branch'`
- Step 2 workflow: listens for pushes to `my-first-branch`
- Step 3 workflow: checks `github.head_ref == 'my-first-branch'`

### Template Guard

All workflows include a guard to prevent execution when the repository itself is the template:
```yaml
if: ${{ !github.event.repository.is_template && ... }}
```

## Workflow Conventions

- **Runner**: All workflows run on `ubuntu-latest`
- **Permissions**: All workflows require `contents: write` (to update step metadata and README)
- **Checkout depth**: `fetch-depth: 0` is used to get all branches
- **Triggers**: Each workflow supports both its primary trigger and `workflow_dispatch` for manual testing
- **Job structure**: Two jobs — `get_current_step` (always runs) and the main job (conditional on step number)

## Key Files to Understand

### `.github/steps/-step.txt`
Single-line file containing the current step number. Do not manually edit during active learner sessions — it is managed by `skills/action-update-step@v2`.

### `.github/steps/*.md`
Markdown fragments injected into `README.md` when a step advances. Each file contains one step's instructions with embedded image references (pointing to `/images/`).

### `README.md`
Dynamically updated by workflows. The content between `<header>` and `<footer>` tags reflects the current step. Do not manually reorder or rename the structural tags.

## Making Changes

### Adding or Modifying Step Content
Edit the relevant file in `.github/steps/`. The `skills/action-update-step@v2` action will inject this content into `README.md` when that step is reached.

### Adding Images
Place PNG files in `images/`. Reference them in step markdown as `/images/filename.png`.

### Modifying Workflows
Each workflow in `.github/workflows/` is numbered to match the step it handles. When modifying trigger conditions, update the `if:` expression on the main job — never remove the `!github.event.repository.is_template` guard.

### Updating Action Versions
Dependabot is configured to check for GitHub Actions updates monthly (see `.github/dependabot.yml`). Both `actions/checkout` (currently `@v4`) and `skills/action-update-step` (currently `@v2`) may receive updates via Dependabot PRs.

## No Build System

This repository has no build system, package manager, test suite, or application code. There is nothing to install, compile, or test. The only "code" is YAML workflow definitions and Markdown content.

## Branch Strategy

- `main`: The primary branch; learner instructions are shown relative to this branch
- `my-first-branch`: The branch learners create during the course (hardcoded in workflows)
- Template repositories generate fresh copies; each learner gets their own isolated instance

## Support

- Discussion board: https://github.com/orgs/skills/discussions/categories/introduction-to-github
- GitHub status: https://www.githubstatus.com/
- License: MIT

# Buehler Bug Workflow

/brainstorming we need to explore the creation of an `/issue` skill to help with various patterns

## Use Cases for `/issue` skill
- capture bugs during development, testing, and review phases (actual behavior ≠ expected behavior)
- capture insights during testing and review phases that lead to new work (e.g. enhancements, refactors, etc.)


## Larger Procedural Context                          
- **priority + severity** needs affordances for both human and AI to make informed decisions about what to work on next, and how to triage and prioritize the work that is already in the backlog.

- **larger procedural context**: completed milestone work at the end    
  of `/integrate` and/or `/review` can be conceptualized as a         
  'release candidate' which will be deployed to *some* environment    
  (dev/qa/prod) where we will run the software, use it, and make      
  note of additional, incremental work that need to be changed,       
  fixed, enhanced, etc. the 'issue' skill is then used to capture     
  these insights, generate GH issues (tied to their nearest parent    
  product story ticket), systematically prioritized and scheduled     
  for execution within the current milestone, and then evaluated    
  for impact on the next milestone's planning and execution.

- **identifying the issue vs documenting the issue:** this happens in three steps: 

1) the agent "spikes" the issue: FIRST AND MOST IMPORTANTLY, the agent looks for duplicate issues to avoid redundancy, if a dupe is found then we add a comment to the existing issue with the new insights and context, and if no dupe is found then we create a new issue as a subissue to the milestone's stabilization ticket (if no stabilization ticket exists, one is created). This step is about quickly capturing the issue from the human in a structured format - creates a parent stabilization ticket if one does not already exist, then creates child issues for each specific problem or enhancement with a URL link to the associated feature ticket in the description.

2) the agent "refines" the issue: adds additional details, context, and insights to the issue over time as they are discovered (e.g. during TDD, debugging, review, etc.), specifically it uses the relevant superpowers skills and then updates the issue with the following information: `superpowers:systematic-debugging` to investigate and document the issue's root cause, reproduction steps, and potential solutions; 

3) uses context from step 2 to recommend a priority and severity level for the issue, which the human operator can approve or override and then updates the issue with these labels (e.g. `priority:high`, `severity:critical`)

## Taste
- JTBD: i want to exit this milestone. if there are issues, i need to fix them before i can exit. if there are no issues, i can exit immediately.

- Orchestration vs context: we want to bias for ease of orchestration, so we will have a single stabilization parent ticket for the milestone, and then all issues will be children of that ticket - with references to their parent ticket so that AI agents assigned to the issue can efficiently do progressive context loading from the parent ticket. This allows us to easily track the progress of the stabilization phase and ensure that all issues are addressed before we can exit the milestone.

general sequence of events:
1. "deploy"
2. "initial test pass / review" - automated evals, TDD, etc (in the event it exists), then human review 
    - (optional) human can provide feedback in the form of GH issue comments, which the agent will then use to create and refine issues as needed
3. "stabilize" - address issues, enhancements, and refactors identified during the review phase; identify which issues can be solved in parallel, and which ones cannot, then check whether we are in **vibe mode** or **pr mode** and then spin up new agents to address the issues in parallel as much as possible, while tracking dependencies and potential conflicts
4. "subsequent test pass" - conduct another round of evaluation to determine if we can exit the milestone or if we need to iterate on the stabilization phase again
5. repeat steps 3 & 4
6. do a thorough retrospective to capture lessons learned and insights for future milestones


decision tree:
after the review step, we have a fork in the road:
1. **vibe mode** - if you have access to main, then you can just fix the issues directly on main and then merge back to your feature branch, which allows you to maintain a clean baseline and avoid merge conflicts. this is the ideal scenario and should be the default approach for handling issues during the stabilization phase.
2. **pr mode** - you do not have access to main
    - create a PR
    - wait for human to review it
    - the human and the AI can have a discussion in the PR comments about the changes
    - AI take comments into account and make revisions as needed, submitting new commits to the PR until the human approves the PR.
    - then human will do the merge, and that will close the issue on it's behalf

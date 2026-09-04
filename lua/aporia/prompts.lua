local M = {}

M.system_prompt = [[
You are a programming tutor. The user is deliberately training their own
problem-solving ability, so your job is to make them think, not to solve
things for them.

Rules:
1. Never write the solution or a code block that could be pasted in as the
   answer. Short illustrative fragments (one or two lines, clearly not the
   answer) are acceptable only when explaining a concept.
2. Prefer questions to statements. Ask one question at a time.
3. Do not escalate hints unless the user explicitly asks for the next level.
4. Every factual claim must end with a verification path: a test the user
   can run, a `:help` topic, a man page, or a specific documentation URL.
   If you cannot give one, say "unverified" next to the claim.
5. If you are unsure, say so. Do not guess confidently.
6. Keep responses short. The user is in an editor, not reading an essay.
7. When pointing at documentation, produce a reference block:
   `name — URL` followed by one line saying what it covers (flag async or
   version caveats). If you need the contents of a doc page to answer, and
   only then, output a single line `FETCH: <url>` and stop.
]]

M.traps = {
  question = {
    desc = "Forming: restate my question, ask for the observable outcome",
    ask = "Your question",
    template = [[Here is my question and the code it is about. Before answering anything,
restate my question in your own words and ask me what observable outcome
I am trying to achieve. Do not proceed until I confirm.

Question: {input}
Code: {selection}]],
  },
  hint = {
    desc = "Dislodging: escalating hints, never the solution",
    ask = "What I've tried",
    template = [[I am stuck on this. Give me hint level 1 only: one question that points me
in the right direction. If I reply "next", give level 2 (name the concept).
If I reply "next" again, give level 3 (point to the docs). Never give the
solution.

Code: {selection}
What I've tried: {input}]],
  },
  reframe = {
    desc = "Assumption: challenge whether this is the right problem",
    ask = "I think the problem is",
    template = [[I think the problem is: {input}

Do not help me solve it. Instead, challenge whether this is the right
problem. Ask what would have to be true for it to be the right problem,
what evidence I have, and what the problem one level up might be.

Context: {selection}]],
  },
  steps = {
    desc = "Location: check reproduce/isolate/hypothesise/test",
    ask = "What I have done so far",
    template = [[Here is what I have done so far to debug this:
{input}

Check this against: reproduce, isolate, hypothesise, test. Tell me only
which step I skipped or did weakly, and ask me one question about it.
Do not do the step for me.

Code: {selection}]],
  },
  rootcause = {
    desc = "Achievement: fix vs patch, invariant, sunk cost",
    ask = nil,
    template = [[I am about to commit this change. Challenge it. Ask me, one at a time:
whether this is a fix or a patch; what invariant was violated; and what I
would do if I had not already invested time in this approach.

Change: {selection}]],
  },
  log = {
    desc = "Progression: two-line summary for the learning log",
    ask = nil,
    template = [[Based on this session, produce exactly two lines and nothing else:
learned: <one line>
still needed AI for: <one line>]],
  },
}

return M

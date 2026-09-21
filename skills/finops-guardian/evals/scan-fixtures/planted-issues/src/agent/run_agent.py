# Fixture: Pattern 7 (unbounded LLM agent loop) — no maximum iteration cap.
def run_agent(task):
    while not task.is_complete():
        response = llm.call(task.get_context())
        task.apply(response)
    return task.result

"""
api.py  ←  FastAPI server

POST /api/run     compile graph → push secrets → inject + push via Docker
POST /api/compile dry run, returns YAML + the spec files it would write
GET  /api/capabilities   frameworks / assertions / action catalog for the UI
"""

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

import config
from schemas import RunRequest, RunResponse
from payload_generator import compile_workflow, generate_shell_script
from testcase_compiler import ASSERTIONS
from docker_runner import run_in_container
from secrets_manager import set_repo_secrets


app = FastAPI(
    title="CI Pipeline Builder API",
    description="Compiles a 7-node-type graph into GitHub Actions YAML + test specs.",
    version="3.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=config.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health_check():
    return {"status": "ok"}


@app.get("/api/capabilities")
def capabilities():
    return {
        "frameworks": ["playwright", "cypress", "jest", "vitest", "bash"],
        "assertions": ASSERTIONS,
        "common_actions": [
            "actions/checkout@v4",
            "actions/setup-node@v4",
            "actions/upload-artifact@v4",
            "actions/download-artifact@v4",
            "actions/cache@v4",
            "actions/upload-pages-artifact@v3",
            "actions/deploy-pages@v4",
        ],
    }


@app.post("/api/compile")
def compile_only(payload: RunRequest):
    nodes, edges = payload.graph()
    try:
        yml, specs = compile_workflow(nodes, edges)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {"compiled_yaml": yml, "spec_files": [{"path": p, "content": c} for p, c in specs]}


@app.post("/api/run", response_model=RunResponse)
def run_workflow(payload: RunRequest):
    nodes, edges = payload.graph()

    # 1. compile
    try:
        ci_yml, spec_files = compile_workflow(nodes, edges)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    # 2. push secrets
    secrets_written: list[str] = []
    if payload.push_secrets and payload.secrets:
        try:
            secrets_written = set_repo_secrets(payload.repo_url, payload.access_token, payload.secrets)
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"Failed to set repo secrets: {exc}") from exc

    # 3. inject + push
    shell_script = generate_shell_script(
        repo_url=payload.repo_url,
        branch=payload.branch,
        container_clone_dir=config.CONTAINER_CLONE_DIR,
        ci_yml_content=ci_yml,
        spec_files=spec_files,
    )
    try:
        logs = run_in_container(
            shell_script=shell_script,
            access_token=payload.access_token,
            image=config.DOCKER_IMAGE,
            timeout=config.CONTAINER_TIMEOUT,
            stream_to_stdout=True,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Unexpected error: {exc}") from exc

    return RunResponse(
        success=True,
        logs=logs,
        message="Pipeline compiled, secrets set, and workflow pushed successfully.",
        compiled_yaml=ci_yml,
        spec_files=[p for p, _ in spec_files],
        secrets_written=secrets_written,
    )


if __name__ == "__main__":
    uvicorn.run("api:app", host=config.API_HOST, port=config.API_PORT, reload=False)

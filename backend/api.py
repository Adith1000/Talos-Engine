"""
api.py  ←  main entry point (FastAPI server)

POST /api/run accepts a node graph (DAG) from the React Flow editor, compiles it
into a GitHub Actions workflow, optionally pushes repo secrets, then injects +
pushes the workflow via the Alpine container.

Run with:
    uvicorn api:app --host 0.0.0.0 --port 8000 --reload
"""

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field, field_validator

import config
from payload_generator import compile_workflow, generate_shell_script
from docker_runner import run_in_container
from secrets_manager import set_repo_secrets


# ─── App setup ───────────────────────────────────────────────────────────────

app = FastAPI(
    title="CI Pipeline Builder API",
    description="Compiles a visual node graph into GitHub Actions YAML and pushes it via Docker.",
    version="2.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=config.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ─── Request / Response schemas ───────────────────────────────────────────────

class FlowNode(BaseModel):
    """A single React Flow node. `data` carries node-specific config
    (e.g. {"framework": "cypress"} for a test node)."""
    id: str
    type: str
    data: dict = Field(default_factory=dict)


class FlowEdge(BaseModel):
    id: str | None = None
    source: str
    target: str


class RunRequest(BaseModel):
    repo_url: str
    access_token: str
    branch: str = "main"

    # The DAG
    nodes: list[FlowNode]
    edges: list[FlowEdge] = Field(default_factory=list)

    # Top-level selections (act as defaults when a node omits its own choice)
    testing_framework: str = "playwright"
    deployment_target: str = "vercel"

    # Repository secrets to push (name -> value)
    secrets: dict[str, str] = Field(default_factory=dict)

    # If False, skip pushing secrets to GitHub (e.g. they already exist)
    push_secrets: bool = True

    @field_validator("repo_url")
    @classmethod
    def must_be_github(cls, v: str) -> str:
        if not v.startswith("https://github.com/"):
            raise ValueError("repo_url must start with https://github.com/")
        return v.strip()

    @field_validator("access_token")
    @classmethod
    def token_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("access_token must not be empty")
        return v.strip()

    @field_validator("testing_framework")
    @classmethod
    def known_framework(cls, v: str) -> str:
        v = v.lower().strip()
        if v not in config.SUPPORTED_FRAMEWORKS:
            raise ValueError(f"Unsupported testing_framework: {v}")
        return v

    @field_validator("deployment_target")
    @classmethod
    def known_target(cls, v: str) -> str:
        v = v.lower().strip()
        if v not in config.SUPPORTED_DEPLOY_TARGETS:
            raise ValueError(f"Unsupported deployment_target: {v}")
        return v

    @field_validator("nodes")
    @classmethod
    def non_empty(cls, v: list[FlowNode]) -> list[FlowNode]:
        if not v:
            raise ValueError("Pipeline must contain at least one node")
        return v


class RunResponse(BaseModel):
    success: bool
    logs: str
    message: str
    compiled_yaml: str
    secrets_written: list[str]


# ─── Routes ──────────────────────────────────────────────────────────────────

@app.get("/health")
def health_check():
    return {"status": "ok"}


@app.get("/api/capabilities")
def capabilities():
    """Lets the frontend discover supported frameworks/targets + their secrets."""
    return {
        "frameworks": sorted(config.SUPPORTED_FRAMEWORKS),
        "deploy_targets": sorted(config.SUPPORTED_DEPLOY_TARGETS),
        "target_secrets": config.TARGET_SECRETS,
    }


@app.post("/api/compile")
def compile_only(payload: RunRequest):
    """Dry run: return the YAML without touching the repo (used by the UI preview)."""
    try:
        yml = compile_workflow(
            nodes=[n.model_dump() for n in payload.nodes],
            edges=[e.model_dump() for e in payload.edges],
            testing_framework=payload.testing_framework,
            deployment_target=payload.deployment_target,
            secrets=payload.secrets,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {"compiled_yaml": yml}


@app.post("/api/run", response_model=RunResponse)
def run_workflow(payload: RunRequest):
    # 1. Compile the DAG -> YAML
    try:
        ci_yml = compile_workflow(
            nodes=[n.model_dump() for n in payload.nodes],
            edges=[e.model_dump() for e in payload.edges],
            testing_framework=payload.testing_framework,
            deployment_target=payload.deployment_target,
            secrets=payload.secrets,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    # 2. Push repo secrets so the workflow's secret refs resolve
    secrets_written: list[str] = []
    if payload.push_secrets and payload.secrets:
        try:
            secrets_written = set_repo_secrets(
                repo_url=payload.repo_url,
                token=payload.access_token,
                secrets=payload.secrets,
            )
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"Failed to set repo secrets: {exc}") from exc

    # 3. Build the container script and run it
    shell_script = generate_shell_script(
        repo_url=payload.repo_url,
        branch=payload.branch,
        container_clone_dir=config.CONTAINER_CLONE_DIR,
        ci_yml_content=ci_yml,
        testing_framework=payload.testing_framework,
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
        secrets_written=secrets_written,
    )


if __name__ == "__main__":
    uvicorn.run("api:app", host=config.API_HOST, port=config.API_PORT, reload=False)
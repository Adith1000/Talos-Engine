"""
schemas.py

Rich request schemas. Each node type carries a typed `data` model, combined
into a discriminated union on `type`, so the API validates (and documents) the
full configuration surface of every node.

These models mirror the frontend node catalog. The compiler in
payload_generator.py consumes plain dicts (model_dump), so the schemas are the
validation + OpenAPI layer; the compiler stays decoupled and unit-testable.
"""

from __future__ import annotations

from typing import Annotated, Literal, Union

from pydantic import BaseModel, Field, field_validator


# ─── Testcase ─────────────────────────────────────────────────────────────────

AssertionType = Literal["contains_text", "element_visible", "status_code", "url_contains"]


class TestCase(BaseModel):
    title: str = "Untitled test"
    route: str = "/"
    assertion: AssertionType = "contains_text"
    expected: str = ""


# ─── Per-node data models ─────────────────────────────────────────────────────

class WorkflowData(BaseModel):
    name: str = "CI Pipeline"


class EventData(BaseModel):
    triggers: list[Literal["push", "pull_request", "workflow_dispatch", "schedule"]] = ["push"]
    push_branches: list[str] = Field(default_factory=lambda: ["main"])
    pull_request_branches: list[str] = Field(default_factory=list)
    cron: str = ""


class JobData(BaseModel):
    jobId: str = "build"
    runsOn: str = "ubuntu-latest"
    timeoutMinutes: int | None = None
    needs: list[str] = Field(default_factory=list)


class RunnerData(BaseModel):
    hosted: bool = True
    image: str = "ubuntu-latest"
    labels: list[str] = Field(default_factory=list)


class StepData(BaseModel):
    name: str = "Step"
    mode: Literal["run", "uses"] = "run"
    run: str = ""
    uses: str = ""
    env: dict[str, str] = Field(default_factory=dict)


class ActionData(BaseModel):
    name: str = ""
    action: str = "actions/checkout@v4"
    withArgs: dict[str, str] = Field(default_factory=dict)


class SecretsData(BaseModel):
    secrets: list[str] = Field(default_factory=list)
    vars: dict[str, str] = Field(default_factory=dict)


class TestSuiteData(BaseModel):
    framework: Literal["playwright", "cypress", "jest", "vitest", "bash"] = "playwright"
    testcases: list[TestCase] = Field(default_factory=list)


# ─── Node union ───────────────────────────────────────────────────────────────
# Each variant pins `type` to a literal; Pydantic uses it as the discriminator.

class _BaseNode(BaseModel):
    id: str


class WorkflowNode(_BaseNode):
    type: Literal["workflow"]
    data: WorkflowData = WorkflowData()


class EventNode(_BaseNode):
    type: Literal["event"]
    data: EventData = EventData()


class JobNode(_BaseNode):
    type: Literal["job"]
    data: JobData = JobData()


class RunnerNode(_BaseNode):
    type: Literal["runner"]
    data: RunnerData = RunnerData()


class StepNode(_BaseNode):
    type: Literal["step"]
    data: StepData = StepData()


class ActionNode(_BaseNode):
    type: Literal["action"]
    data: ActionData = ActionData()


class SecretsNode(_BaseNode):
    type: Literal["secrets"]
    data: SecretsData = SecretsData()


class TestSuiteNode(_BaseNode):
    type: Literal["testsuite"]
    data: TestSuiteData = TestSuiteData()


PipelineNode = Annotated[
    Union[
        WorkflowNode, EventNode, JobNode, RunnerNode,
        StepNode, ActionNode, SecretsNode, TestSuiteNode,
    ],
    Field(discriminator="type"),
]


class FlowEdge(BaseModel):
    id: str | None = None
    source: str
    target: str


# ─── Top-level request ────────────────────────────────────────────────────────

class RunRequest(BaseModel):
    repo_url: str
    access_token: str
    branch: str = "main"

    nodes: list[PipelineNode]
    edges: list[FlowEdge] = Field(default_factory=list)

    # name -> value; pushed to GitHub as encrypted repo secrets
    secrets: dict[str, str] = Field(default_factory=dict)
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

    @field_validator("nodes")
    @classmethod
    def non_empty(cls, v: list) -> list:
        if not v:
            raise ValueError("Pipeline must contain at least one node")
        return v

    def graph(self) -> tuple[list[dict], list[dict]]:
        """Plain-dict form for the compiler."""
        return (
            [n.model_dump() for n in self.nodes],
            [e.model_dump() for e in self.edges],
        )


class RunResponse(BaseModel):
    success: bool
    logs: str
    message: str
    compiled_yaml: str
    spec_files: list[str]
    secrets_written: list[str]

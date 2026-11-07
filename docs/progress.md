# Progress against the project brief

Last updated: 7 November 2026

**Where it stands:** everything that can run without an AWS account is built, tested and passing on GitHub. 4 of the brief's 5 demos are done and recorded as GIFs. Nothing has been created on AWS yet. That needs an AWS account and a decision to spend about $0.34 an hour (estimate).

## What was built

A small lead-processing app: a FastAPI service takes leads by webhook, a worker scores them from a Redis queue, and PostgreSQL stores them. Around it sit the Dockerfiles, a Compose stack, a Helm chart that deploys to kind and EKS, Terraform for AWS, and three GitHub Actions workflows.

## Progress by part of the brief

| Part | Status | Notes |
| --- | --- | --- |
| 1. Containers | **Done** | Multi-stage, non-root, health checks. API image went from 1.71 GB to 242 MB. |
| 2. CI/CD | **CI passes on GitHub. Deploy waits for AWS.** | All 8 CI jobs passed on the first run, in 2.5 minutes. `deploy.yml` and `terraform.yml` need AWS, so they have not done a real run. |
| 3. Terraform | **Written. Not applied.** | 32 offline test runs pass against a mocked AWS. That proves the wiring, not that AWS accepts it. |
| 4. Kubernetes | **Done on kind** | Probes, autoscaling, migration Job and rollback all ran. The ALB Ingress needs AWS, so it has not run. |

## Demos in the brief

| Demo | Status |
| --- | --- |
| Self-healing | **Done.** Pods replaced in 3 to 14 seconds. No lead lost in a Redis outage. |
| Rollback | **Done.** 3 broken releases recovered, 1,116 requests, 0 failed. |
| Autoscaling | **Done.** 1 to 4 pods and back, 21,964 requests, 0 failed, p95 266 ms. |
| Pipeline gate | **Done.** A one-line bug failed 4 of 8 checks, including the required one, and GitHub marked the pull request `BLOCKED`. |
| Destroy and rebuild | **Waiting on AWS.** |

Each demo has a GIF and a transcript in [docs/demos](demos/), plus a screenshot of the failed CI run for the gate. The GIFs are rendered from the live script output by `scripts/demos/record_gif.py`, not by a screen recorder, with waits shortened and real elapsed time on every frame.

## Problems found and fixed

Testing found real bugs. The README has the full details and numbers.

1. **Redis outages froze the API for 46 seconds,** because of the Redis library's default retries.
2. **A Redis outage took the whole API offline,** because the readiness check depended on Redis.
3. **A broken release could stay live,** because the rollback step needed a tool that was not installed.
4. **Every health probe used almost a full CPU second,** which wasted about 120m CPU on an idle worker.
5. **Every deploy restarted Redis,** because of a version label on its pod.
6. **"Vice President" scored as a president,** which a unit test caught.
7. **`kind load` failed on multi-platform images,** so the images are now exported one platform at a time.
8. **A demo reported PASS on a result it never saw,** because the pipeline gate script found its CI run by branch name and read the previous day's run. It now matches by commit and checks that the required check itself failed.

## What is left

| Item | Who | Rough time |
| --- | --- | --- |
| An AWS account, and approving the spend | **You** | Your call |
| First real `terraform apply`, fixing what AWS rejects | After that | Half a day, including fixes |
| Staging and production deploys, ALB, rebuild demo | After that | Included above |

# LeadPipe runbook

These are the steps for operating LeadPipe on AWS.

> **The AWS paths in this runbook have not been run yet.** The commands come from the scripts and from AWS documentation. Correct them after the first real run.

The commands assume these settings, and that you start at the repository root. Replace `staging` with `production` where needed.

```bash
export AWS_REGION=ap-south-1
```

## First-time setup

Do these in order. Each step depends on the one before it.

| Step | Command or action | What it does |
| --- | --- | --- |
| 1 | Create the GitHub repository | The AWS roles trust it by name |
| 2 | `terraform apply` in `infra/bootstrap` | Budget alert, state bucket, GitHub OIDC provider, Terraform roles |
| 3 | Confirm the budget alert in the AWS Budgets console | Do this before anything that bills by the hour exists |
| 4 | `terraform init -backend-config=...`, then `terraform apply`, in `infra/main` | VPC, EKS, RDS, ECR, IAM, empty API key secrets |
| 5 | `scripts/cluster-bootstrap.sh` | Namespaces, API key values, AWS Load Balancer Controller |
| 6 | `scripts/github-setup.sh <aws-account-id> <region>` | Repository variables, environments, merge gate |
| 7 | Merge to `main` | The first deploy |

The exact commands for steps 2 and 4 are in the [README](../README.md#run-it-on-aws).

An account can have only one OIDC provider for GitHub. If yours already has one, bootstrap's apply will fail on it. Import the existing provider into the bootstrap state before applying again.

## Routine deploy

**Application change:**

1. Open a pull request. CI must pass, and `CI passed` is the required check.
2. Merge it. The Deploy workflow builds, scans and pushes the images, then deploys to staging.
3. Check staging, then approve the `production` deployment on the workflow run page.

`scripts/deploy.sh` smoke-tests each deploy and rolls back on failure, so a red deploy job has normally already recovered. Confirm with `helm history`.

**Infrastructure change:**

1. Open a pull request. The Terraform workflow posts the plan as a comment.
2. Read the plan, then merge.
3. Approve the `infrastructure` deployment on the workflow run page.

**Re-run a deploy without new code:**

```bash
gh workflow run deploy.yml --ref main
```

ECR tags are immutable, so the build job skips any image that is already pushed.

## Manual rollback

See what is deployed:

```bash
helm history leadpipe -n staging
```

Go back to the previous release. Revision `0` means the previous one.

```bash
helm rollback leadpipe 0 -n staging --wait --timeout 5m
```

Or go back to a specific revision:

```bash
helm rollback leadpipe <revision> -n staging --wait --timeout 5m
```

Rollback restores the old pods but does not undo the database schema. Migrations are forward-only, so each one must stay compatible with the previous release. To fix a bad migration, add a new one.

## Rotate the database password

RDS rotates the password on its own every 365 days (`password_rotation_days` in `infra/modules/rds`). Pods read the password when they start, so every rotation needs a redeploy. Until then, existing database connections keep working but new ones fail.

Rotate now:

```bash
aws rds modify-db-instance --db-instance-identifier leadpipe --rotate-master-user-password --apply-immediately
```

Wait until this prints `active`:

```bash
aws rds describe-db-instances --db-instance-identifier leadpipe --query 'DBInstances[0].MasterUserSecret.SecretStatus' --output text
```

Then redeploy:

```bash
gh workflow run deploy.yml --ref main
```

`scripts/deploy.sh` copies the new password into the Kubernetes Secret, and changes a hash on the pods so they restart with it. `kubectl rollout restart` alone is not enough, because the Kubernetes Secret would still hold the old password.

Both environments share this password, so approve the production deployment promptly.

## Read logs and state

Both services write JSON logs to stdout, with `time`, `level`, `logger` and `message` fields. Lead emails are not logged.

```bash
kubectl -n staging logs deploy/leadpipe-api --tail=50 -f
```

```bash
kubectl -n staging logs deploy/leadpipe-worker --tail=50 -f
```

Show errors only:

```bash
kubectl -n staging logs deploy/leadpipe-worker --tail=500 | jq -c 'select(.level == "ERROR" or .level == "WARNING")'
```

Overall state and recent events:

```bash
kubectl -n staging get pods,hpa,ingress
```

```bash
kubectl -n staging get events --sort-by=.lastTimestamp
```

Queue depth, and jobs read but not yet acknowledged:

```bash
kubectl -n staging exec deploy/leadpipe-redis -- redis-cli XLEN leads:jobs
```

```bash
kubectl -n staging exec deploy/leadpipe-redis -- redis-cli XPENDING leads:jobs scorers
```

Read an API key, for testing:

```bash
aws secretsmanager get-secret-value --secret-id leadpipe/staging/api-key --query SecretString --output text
```

## Teardown

```bash
scripts/aws-down.sh
```

This removes the apps from both namespaces, waits for the controller to delete the load balancers, removes the controller, and runs `terraform destroy` in `infra/main`. It needs an initialised `infra/main`, with its `terraform.tfvars` in place.

The state bucket, budget and Terraform roles stay, because a rebuild needs them. To remove those too, delete the `prevent_destroy` block from the bucket in `infra/bootstrap/main.tf`, empty the bucket including old versions, and run `terraform destroy` there.

Check the AWS Billing console a few hours later to confirm the charges have stopped.

## Re-record a demo

Each demo in `scripts/demos/` can be recorded as a GIF and a transcript in `docs/demos/`. Run it through `record_gif.py`:

```bash
scripts/demos/autoscaling.sh 2>&1 | python scripts/demos/record_gif.py --command scripts/demos/autoscaling.sh --out docs/demos/autoscaling
```

This needs Pillow (`pip install Pillow`). The services do not use it.

`scripts/demos/rollback.sh` takes one argument: the image tag of the good release now deployed. `scripts/demos/pipeline-gate.sh` takes no arguments. It opens a real pull request on GitHub with a one-line bug, waits for CI, and then closes the pull request.

## Troubleshooting

### `Not authorized to perform sts:AssumeRoleWithWebIdentity`

The token GitHub sent does not match the subject the AWS role trusts.

| Role | Trusted subject |
| --- | --- |
| `leadpipe-terraform-plan` | `repo:<owner>/<repo>:pull_request` |
| `leadpipe-terraform-apply` | `repo:<owner>/<repo>:environment:infrastructure` |
| `leadpipe-gha-ecr-push` | `repo:<owner>/<repo>:ref:refs/heads/main` |
| `leadpipe-gha-deploy-staging` | `repo:<owner>/<repo>:environment:staging` |
| `leadpipe-gha-deploy-production` | `repo:<owner>/<repo>:environment:production` |

Check these in order:

1. `github_repository` in both `terraform.tfvars` files matches the repository exactly. A renamed or transferred repository needs a new apply.
2. The run is in the right context. `leadpipe-gha-ecr-push` works only on `main`, so `workflow_dispatch` from another branch fails.
3. The job declares the environment that the role expects.
4. The repository has not customised its OIDC subject claims. Customising changes the subject format.
5. The bootstrap apply actually ran in this AWS account.

To see the subject AWS received, search CloudTrail for `AssumeRoleWithWebIdentity` events and read the failed event.

### The migration Job failed

Helm stops the upgrade, and `--rollback-on-failure` restores the previous release. The old pods keep serving.

A failed Job stays in place until the next deploy, so you can read its logs:

```bash
kubectl -n staging logs job/leadpipe-migrate
```

```bash
kubectl -n staging describe job leadpipe-migrate
```

| Log or event | Likely cause | Fix |
| --- | --- | --- |
| `database not reachable`, repeated | Security group, wrong host, or RDS still starting | Confirm the instance is available, and that the rule allows the cluster security group |
| `password authentication failed` | The password rotated and the Secret is out of date | Redeploy. `deploy.sh` refreshes the Secret first. |
| `CreateContainerConfigError` | `leadpipe-secrets` is missing | Run `scripts/deploy.sh`, not `helm upgrade` by hand |
| An SQL error | A bad migration | Each file runs in a transaction, so nothing is half-applied. Fix the SQL and deploy again. |

### `terraform destroy` hangs on the VPC or subnets

The AWS Load Balancer Controller creates ALBs and their security groups outside Terraform. If they still exist, their network interfaces block deleting the subnets and the VPC. This happens when `terraform destroy` is run directly, instead of `scripts/aws-down.sh`, or when the controller was removed first.

Find what is left. Get the VPC ID from `terraform -chdir=infra/main output -raw vpc_id`.

```bash
aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='<vpc-id>'].[LoadBalancerName,LoadBalancerArn]" --output table
```

```bash
aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc-id> --query 'NetworkInterfaces[].[NetworkInterfaceId,Description,Status]' --output table
```

Delete the ALBs and their target groups in the EC2 console. Then delete any leftover security groups in the VPC with names starting `k8s-`. ALB network interfaces can take a few minutes to go. Then run `terraform destroy` again.

### `deploy.sh` fails with `ResourceNotFoundException` on an API key

The error says Secrets Manager cannot find a value for `leadpipe/<env>/api-key` at stage `AWSCURRENT`.

Terraform creates these secrets empty on purpose, so the value never enters Terraform state. `scripts/cluster-bootstrap.sh` generates it. Run that script. The Terraform workflow's apply job also runs it.

A rebuild creates new, empty secrets, so it also creates new API keys. Update any webhook callers afterwards.

### Pods are stuck

| Status | Likely cause | Fix |
| --- | --- | --- |
| `ImagePullBackOff` | The image tag is not in ECR | Check that the build job pushed this commit |
| `CreateContainerConfigError` | `leadpipe-secrets` is missing from the namespace | Run `scripts/deploy.sh` |
| `CrashLoopBackOff` with `missing required environment variables` | Configuration is incomplete | The error lists every missing name |
| `Running`, but never ready | `/readyz` failing | Run `kubectl -n staging exec deploy/leadpipe-api -- python -c "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8000/healthz').read())"`, and check the API logs |

### `/readyz` returns 503, or reports `degraded`

The response names the failing dependency.

A 503 means PostgreSQL is unreachable. The pod leaves the Service until the database responds, because it cannot save leads:

```json
{"status": "not ready", "checks": {"database": "unavailable", "redis": "ok"}}
```

A 200 with `degraded` means only Redis is down. The pod stays in service on purpose:

```json
{"status": "degraded", "checks": {"database": "ok", "redis": "unavailable"}}
```

Leads posted during a Redis outage are still saved. The worker's sweep queues them again once Redis is back and the stream is empty. Allow up to about 90 seconds. Check the worker log for `re-queued`.

### The Ingress has no address

```bash
kubectl -n staging describe ingress leadpipe-api
```

```bash
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50
```

Common causes are a controller that is not running, or missing `kubernetes.io/role/elb` tags on the public subnets. Run `scripts/cluster-bootstrap.sh` if the controller is missing. A new ALB can take a few minutes to become active.

### The HPA shows `<unknown>` for CPU

`metrics-server` is not ready. It also needs about a minute of data after a pod starts.

```bash
kubectl top pods -n staging
```

```bash
kubectl -n kube-system get deploy metrics-server
```

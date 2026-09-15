# Golem Docker Compose Deployment Scripts

This directory contains Docker Compose configurations and automation scripts for deploying Golem using docker.

## Contents

- **docker-compose.yaml** - Main Docker Compose configuration for all Golem services
- **.env** - Environment variables for local/development deployment
- **nginx.conf.template** - Nginx configuration for routing requests
- **aws-deploy-ec2.sh** - Automated deployment script for AWS EC2
- **aws-cleanup-ec2.sh** - Cleanup script to remove AWS resources

## Quick Start (Deploy to AWS EC2)

### Prerequisites

1. **AWS Account** with EC2 access
2. **AWS CLI** installed and configured:
   ```bash
   aws configure
   ```
3. **SSH Key Pair** created in AWS EC2:
   ```bash
   # Create a key pair if you don't have one
   aws ec2 create-key-pair --key-name golem-key --query 'KeyMaterial' --output text > ~/.ssh/golem-key.pem
   chmod 400 ~/.ssh/golem-key.pem
   ```
4. **jq** installed (for JSON parsing):
   ```bash
   brew install jq  # macOS
   ```

### Deploy Golem to EC2

From this directory, run:

```bash
./aws-deploy-ec2.sh --key-name golem-key --region us-east-1
```

The script will:
1. ✅ Verify prerequisites
2. ✅ Create security group with proper rules
3. ✅ Launch EC2 instance (t3.medium by default — t3.small's 1.9 GiB RAM gets OOM-killed once worker-executor actually runs an agent; override with `--instance-type` if you need something larger)
4. ✅ Install Docker and Docker Compose
5. ✅ Deploy all Golem services
6. ✅ Verify the deployment
7. ✅ Provide access URLs and next steps

**Deployment time:** ~10-15 minutes

### Access Your Deployment

After deployment completes, you'll get:

```
Instance Details:
  Instance ID:  i-1234567890abcdef0
  Public IP:    54.123.45.67
  Region:       us-east-1

Golem Endpoints:
  Router:       http://54.123.45.67:9881
  Worker API:   http://54.123.45.67:9006
```

### Deploy Your Components

- configure the golem.yaml manifests <host> substitutions of the intest sections.
- configure the main golem.yaml manifests <ADMIN_TOKEN> substitution with the respective parameter store value*
- execute `golem deploy --environment intest` or `npm run deploy:intest`

*You may not want to commit this token value to a source repository!

### Test the Deployment

Test the counter agent using its API, same as the [root README](../../README.md), but against the EC2 host's
`httpApi.deployments.intest` domain (worker-service's custom request port `9006` — not the nginx router on `9881`,
which doesn't route agent HTTP mounts):

```shell
curl -X POST http://ec2-<host>.compute.amazonaws.com:9006/counters/agent-1/increment
```

This should return `1.0`.

## Local Development (Docker Compose)

You can run the full stack locally without EC2, e.g. for integration testing. Unlike the EC2 path, there's no
Parameter Store to source secrets from, so `ADMIN_TOKEN`, `MARKETING_TOKEN`, and `CORS_ORIGIN_REGEX` must be
supplied yourself — they're intentionally not committed to `.env`.

From this directory:

```bash
export ADMIN_TOKEN=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')
export MARKETING_TOKEN=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')
export CORS_ORIGIN_REGEX=".*"

docker-compose up -d
docker-compose ps
docker-compose logs -f golem-shard-manager golem-worker-executor
```

Tear down with `docker-compose down` (add `-v` to also drop the `postgres_data`/`redis_data`/`blob_storage` volumes
and start from a clean database).

## Cleanup (Deploy to AWS EC2)

When you're done, clean up all AWS resources:

```bash
# Clean up specific instance (add --key-name to also delete the SSH key pair)
./aws-cleanup-ec2.sh --instance-id i-1234567890abcdef0 --key-name golem-docker-compose-key --region us-east-1

# OR clean up all Golem instances in a region
./aws-cleanup-ec2.sh --all --region us-east-1
```

The cleanup script will:
1. Terminate the EC2 instance(s)
2. Delete the security group (if not in use)
3. Delete the SSH key pair, both in AWS and the local `~/.ssh/<key-name>.pem` file (only if `--key-name` is given)
4. Delete all Parameter Store parameters under `/golem/docker`
5. Delete the IAM instance profile and role

It asks for interactive confirmation (once before deleting anything, once more if a local key file is found) — for
scripted/non-interactive use, pipe answers in: `printf 'yes\nyes\n' | ./aws-cleanup-ec2.sh ...`.

## Architecture

The Docker Compose stack includes:

```
┌─────────────────────────────────────────┐
│         Nginx Router (Port 9881)        │
│              Reverse Proxy              │
└─────────────────────────────────────────┘
                   │
    ┌──────────────┼──────────────┐
    │              │              │
┌───▼────┐    ┌────▼───┐    ┌─────▼────┐
│Registry│    │Worker  │    │Debugging │
│Service │    │Service │    │Service   │
└────────┘    └────┬───┘    └──────────┘
                   │
         ┌─────────┼────────┐
         │                  │
    ┌────▼────┐      ┌──────▼──────┐
    │Worker   │      │Shard        │
    │Executor │      │Manager      │
    └─────────┘      └─────────────┘
         │                  │
    ┌────▼────┐      ┌──────▼──────┐
    │Component│      │             │
    │Compile  │      │             │
    └─────────┘      │             │
                     │             │
          ┌──────────┴─────────┐   │
          │                    │   │
    ┌─────▼────┐         ┌─────▼───▼┐
    │PostgreSQL│         │   Redis  │
    │(Database)│         │  (Cache) │
    └──────────┘         └──────────┘
```

## Services

| Service | Port | Description |
|---------|------|-------------|
| **Router** | 9881 | Main entry point, reverse proxy |
| **Worker Service** | 9006 | Worker API Gateway |
| **Worker Service** | 9009 | MCP protocol endpoint (not routed by nginx) |
| **Registry Service** | 8083 | Component registry |
| **Worker Executor** | 8082 | Executes worker instances |
| **Shard Manager** | 8081 | Manages worker shards |
| **Compilation Service** | 8084 | Compiles components |
| **Debugging Service** | 8086 | Debug support |
| **PostgreSQL** | 5432 | Database |
| **Redis** | 6379 | Cache & state |

## Storage Backends

Every durable service is backed by Postgres; Redis is used purely as a cache/session layer, so local/integration
testing stays representative of a production deployment backed by managed Postgres + Redis.

| Service | Durable state (Postgres) | Cache (Redis) |
|---------|---------------------------|----------------|
| **Registry Service** | `golem_db`, schema `public` | — |
| **Shard Manager** | `golem_db`, schema `shard_manager` | — |
| **Worker Executor** | `golem_db`, schema `worker_executor_scheduler` (scheduled/delayed invocations) | Key-value store, indexed storage |
| **Debugging Service** | `golem_db`, schema `debugging_service_scheduler` | Key-value store, indexed storage |
| **Worker Service** | — | Gateway session storage |

All schemas live in the single `golem_db` database (set via `POSTGRES_DB` on the `postgres` service in
`docker-compose.yaml`) and are created automatically on first
startup via `CREATE SCHEMA IF NOT EXISTS` — no manual database setup or init scripts are needed. Nothing that must
survive a restart (scheduled invocations, shard assignments, account/component data) is stored in Redis; anything
in Redis is safe to lose and gets rebuilt.

## Security Considerations

⚠️ **Important Security Notes:**

1. **SSH Access**: The default script allows SSH from any IP (0.0.0.0/0). For production, restrict to your IP:
   ```bash
   aws ec2 authorize-security-group-ingress \
     --group-id sg-xxx \
     --protocol tcp \
     --port 22 \
     --cidr YOUR_IP/32
   ```

2. **API Access**: Golem endpoints are publicly accessible. For production:
   - Use AWS security groups to restrict access
   - Set up VPN or bastion host
   - Add authentication layer
   - Use AWS ALB with SSL/TLS

3. **Credentials**: Change default credentials for production use:

   - POSTGRES_PASSWORD

4. **Tokens**: These are in AWS Parameter Store consider using Secret Manager for stronger security.

Keep versions updated.
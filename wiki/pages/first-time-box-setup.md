# First-Time Edge Box Setup

Enrolling the client's on-site edge box is the **first step** of onboarding a new factory (csadmin onboarding wizard, step 1: "Set up the client box"). Nothing else edge-side — deploying the reader/agent bundle, probing PLCs, capturing counts — can happen until this is done, because the cloud has no route into the factory network.

## Why a box exists at all

AWS has **no network route to a factory LAN**. The PLCs live on a private subnet (e.g. `192.168.5.0/24`) behind the client's firewall — the cloud can't dial into them, and opening inbound ports on a plant network is unacceptable. So every client needs a small **on-site computer — the edge box** — that sits on both networks: it can reach the PLCs on the LAN and reach the internet outbound.

The cloud operates that box without any inbound ports using **AWS SSM hybrid activation**: the SSM agent on the box polls AWS *outbound* over 443 and keeps the channel open, so "cloud → box" commands ride a connection the box itself opened (the same idea as a reverse SSH tunnel, or a WireGuard/Tailscale client staying reachable behind NAT). Once enrolled, the box appears in AWS as a **managed instance** (`mi-xxxxxxxx`) and you can run commands / open sessions against it as if it were EC2.

## The three layers

### Layer 1 — physical prerequisites (a human, on-site or with remote access to the box)

Before any csadmin action, the box must exist and be reachable:

- An actual computer at the factory (mini-PC / industrial gateway / VM), powered on, on the plant network.
- **Two reachabilities:** (a) it can reach the PLC subnet, and (b) it has outbound internet on **443** (AWS SSM) and later **8883** (mTLS to the ingest endpoint for the data uplink).
- A supported **Linux** with **Docker** (the edge bundle runs as containers) and **sudo/root** (to install the SSM agent).

> The box does **not** need to be modern — a real client box runs EOL Ubuntu 18.04; the SSM agent and Docker run fine there even where newer tooling can't.

If any of Layer 1 isn't true, no amount of clicking in csadmin helps.

### Layer 2 — enrollment (csadmin onboarding step 1)

1. csadmin onboarding → step 1 **"Set up the client box"** → **Enroll this client's box**. The backend calls SSM `CreateActivation` and returns an **activation id + code** (a short-lived registration secret) and a **one-line register command**.
2. **Run that command once on the box, as root.** It installs `amazon-ssm-agent`, registers it with the activation id/code + region, tags the box (`managed-by=packiot-edge-api`, `enterprise=<id>`), and starts the agent.
3. The step **auto-polls** until the box reports **Online**, then hands the resolved `mi-…` id to the later steps.

The one manual action is getting the register command onto the box (SSH in, or hand it to whoever is physically there). Everything after that is cloud-driven.

### Layer 3 — everything after (the box is now reachable)

4. Build the hierarchy (site / area / lines / machines) — can proceed in parallel while the box comes online.
5. Connect the PLCs (the descriptor / connections editor).
6. **Deploy the edge bundle** — pushed to the box via SSM `SendCommand` → `docker compose up` the reader + agent. This works only because the box is enrolled (the deploy step guards against an unenrolled box).
7. **Probe / verify** PLC reachability (the Test button routes cloud → box via SSM → the agent does the actual TCP dial on the LAN).
8. Go live / capture.

## Greenfield vs. an already-enrolled box

- **Already-enrolled client:** step 1 loads, `GET status` finds the box **Online**, and shows green "connected (`mi-…`)" — click through to the hierarchy/PLC steps.
- **Greenfield client (no box):** step 1 shows the **Enroll** action → do Layer 1 first (a computer that can see the PLCs and reach the internet, with Docker + root) → enroll → run the command → wait for Online → then the rest.

## Quick reference

| Layer | Who | What |
|---|---|---|
| 1 — Physical | Field / client | On-site Linux box; reaches PLC LAN + outbound 443/8883; Docker + root |
| 2 — Enroll | CS engineer (csadmin) | Step 1 → Enroll → run register command on box → wait for Online |
| 3 — Configure & deploy | CS engineer (csadmin) | Hierarchy → connect PLCs → deploy bundle → probe → go live |

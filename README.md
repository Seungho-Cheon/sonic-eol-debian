# SONiC-Based Smart White Box Switch for AI/LLM Workloads

A high-performance, cost-effective, and open-source network infrastructure built using SONiC (Software for Open Networking in the Cloud) NOS and White Box Switches. This project eliminates vendor lock-in and optimizes networks for intensive AI and Large Language Model (LLM) training and inference workloads.

## 🚀 Key Highlights

* **High-Performance Infrastructure:** Delivers high bandwidth, ultra-low latency, and lossless networking to handle skyrocketing AI/LLM data traffic.
* **Vendor Decoupling:** Replaces high-cost proprietary legacy networking equipment (e.g., Cisco) with an agile, open-source hardware/software ecosystem.
* **Cost Innovation:** 
  * Reduces inference infrastructure costs by **50%** through the integration of native DPU and NPU technologies.
  * Lowers overall deployment costs by approximately **40%** by eliminating vendor lock-in.

---

## 🛠️ Key Technologies & Features

* **SONiC NOS & White Box Switch:** Deployed open-source network operating system on flexible, scalable bare-metal hardware.
* **RoCEv2 (RDMA over Converged Ethernet):** Implemented high-performance fabric support utilizing RDMA to bypass OS kernels for direct memory transfers.
* **Switch Abstraction Interface (SAI):** Seamlessly integrated with SAI to provide a unified API layer for controlling underlying White Box ASIC chipsets.
* **Redis DB Architecture:** Managed containerized internal states, configurations, and telemetry using the multi-tier Redis database structure:
  * Application DB (`AppDB`)
  * ASIC DB (`AsicDB`)
  * Configuration DB (`ConfigDB`)
  * State DB (`StateDB`)

---

## 📂 Repository Info & Branch Target

* **GitHub Repository:** [sonic-eol-debian](https://github.com/Seungho-Cheon/sonic-eol-debian)
* **Active Branch:** `202311.X_9817_32`

---

## 🏗️ Architecture Overview

SONiC Applications -> Redis DB (AppDB / ConfigDB / StateDB / AsicDB) -> SAI (Switch Abstraction Interface) -> White Box ASIC (DPU / NPU / Fabric)


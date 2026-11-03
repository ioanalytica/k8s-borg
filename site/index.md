---
layout: home
title: k8s-borg
titleTemplate: BorgBackup for Kubernetes
hero:
  name: k8s-borg
  text: BorgBackup for Kubernetes
  tagline: One Helm chart backs up the nodes, the cluster datastore, databases, S3 buckets and shared file systems into Borg repositories, deduplicated and encrypted on the client.
  actions:
    - theme: brand
      text: Install
      link: /guide/install
    - theme: alt
      text: Introduction
      link: /guide/
    - theme: alt
      text: GitHub
      link: https://github.com/ioanalytica/k8s-borg
features:
  - icon: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="7" rx="1.5"/><rect x="3" y="13" width="18" height="7" rx="1.5"/><path d="M7 7.5h.01M7 16.5h.01M11 7.5h6M11 16.5h6"/></svg>'
    title: Node backups
    details: A DaemonSet backs up each node's own file systems into a repository per node, without the kubelet volumes and network mounts below them.
    link: /features/node-backups
  - icon: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 3 7.5l9 4.5 9-4.5z"/><path d="m3 12 9 4.5 9-4.5"/><path d="m3 16.5 9 4.5 9-4.5"/></svg>'
    title: Cluster datastore
    details: A consistent snapshot of etcd or k3s's SQLite on the control-plane nodes, with the token or PKI a rebuilt control plane needs.
    link: /features/datastore
  - icon: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="12" cy="5.5" rx="7.5" ry="2.5"/><path d="M4.5 5.5v13c0 1.4 3.4 2.5 7.5 2.5s7.5-1.1 7.5-2.5v-13"/><path d="M4.5 12c0 1.4 3.4 2.5 7.5 2.5s7.5-1.1 7.5-2.5"/></svg>'
    title: Database dumps
    details: MariaDB, MySQL, Percona Server, PostgreSQL, MongoDB, Redis and Valkey, with credentials from the operators' Secrets, left uncompressed so that Borg deduplicates them.
    link: /features/databases
  - icon: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7.5A1.5 1.5 0 0 1 4.5 6H9l2 2h8.5A1.5 1.5 0 0 1 21 9.5v8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5z"/><path d="m9 13.5 2 2 4-4"/></svg>'
    title: S3 and shared file systems
    details: Buckets are mounted fresh and checked against their listing before each run; shared volumes and user homes go into the same backup.
    link: /features/s3
  - icon: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="7" height="7" rx="1"/><rect x="13" y="4" width="7" height="7" rx="1"/><rect x="4" y="13" width="7" height="7" rx="1"/><rect x="13" y="13" width="7" height="7" rx="1"/></svg>'
    title: Repository server
    details: Optional borg serve over SSH, unprivileged, each client key bound to its own directory, with a copy of the repositories on S3 or SFTP.
    link: /features/repository-server
  - icon: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12a8 8 0 1 0 2.4-5.7"/><path d="M4 4v4h4"/><path d="m9 12 2 2 4-4"/></svg>'
    title: Tested restores
    details: Every engine's dump and restore runs against real servers in CI on every push, and each restore is written down step by step.
    link: /operations/restore
---

## How it fits together

<!--@include: ../README.md#architecture-->

Each node backs up into a repository of its own, and the cluster data into
another; the console pod has the Borg tools at hand for inspection and
restores. With Borg UI, the node and console pods run as managed agents of a
Borg UI server, one the chart deploys or an existing one; the UI itself is
[Borg UI](https://github.com/karanhudia/borg-ui), documented at
[docs.borgui.com](https://docs.borgui.com).

## Quick start

<!--@include: ../README.md#quick-start-->

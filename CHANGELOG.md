# Changelog

## 1.1.9-beta.6

* **New value `s3.region`**, the SigV4 region of the S3 endpoint. It reaches
  s3fs as `endpoint=<region>` (env `S3_REGION`). S3 servers that check the
  region, such as Garage, refuse every request s3fs signs for its default
  `us-east-1`. Empty keeps the s3fs options as before.
* **A bucket that does not answer now stops the pod's start.** s3fs reports
  success and leaves a mount behind even with a wrong region, wrong
  credentials, a missing bucket or an unreachable endpoint; the first access
  then blocks until s3fs is killed, while s3fs keeps polling the server. The
  new `s3-mount-bucket` lists every fresh mount within `S3_PROBE_TIMEOUT`
  seconds (default 30); on failure it removes the mount, ends s3fs and stops
  with the bucket, endpoint and region in the message.
* Borg UI unchanged: 2.3.8, agent 0.1.17.

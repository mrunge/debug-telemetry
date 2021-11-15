# Debugging OpenStack Metrics


## Overview


We'll do the following steps:

1. check if metrics are getting in 
2. if not, check if ceilometer is running
3. check if gnocchi is running
4. 



### Check that metrics are getting in

`openstack server list`

example:

```
$ openstack server list  -c ID -c Name -c Status
+--------------------------------------+-------+--------+
| ID                                   | Name  | Status |
+--------------------------------------+-------+--------+
| 7e087c31-7e9c-47f7-a4c4-ebcc20034faa | foo-4 | ACTIVE |
| 977fd250-75d4-4da3-a37c-bc7649047151 | foo-2 | ACTIVE |
| a1182f44-7163-4ad9-89ed-36611f75bac7 | foo-5 | ACTIVE |
| a91951b3-ff4e-46a0-a5fd-20064f02afc9 | foo-3 | ACTIVE |
| f0a62c20-2304-4c8c-aaf5-f5bc9d385b5f | foo-1 | ACTIVE |
+--------------------------------------+-------+--------+
```

We'll use `f0a62c20-2304-4c8c-aaf5-f5bc9d385b5f`. That's the uuid of the server `foo-1`. For convenience, the server uuid and the resource ID used in `openstack metric resource` are the same.

```
$ openstack metric resource show f0a62c20-2304-4c8c-aaf5-f5bc9d385b5f
+-----------------------+-------------------------------------------------------------------+
| Field                 | Value                                                             |
+-----------------------+-------------------------------------------------------------------+
| created_by_project_id | 6a180caa64894f04b1d04aeed1cb920e                                  |
| created_by_user_id    | 39d9e30374a74fe8b58dee9e1dcd7382                                  |
| creator               | 39d9e30374a74fe8b58dee9e1dcd7382:6a180caa64894f04b1d04aeed1cb920e |
| ended_at              | None                                                              |
| id                    | f0a62c20-2304-4c8c-aaf5-f5bc9d385b5f                              |
| metrics               | cpu: fe84c113-f98d-42ee-84fd-bdf360842bdb                         |
|                       | disk.ephemeral.size: ad79f268-5f56-4ff8-8ece-d1f170621217         |
|                       | disk.root.size: 6e021f8c-ead0-46e4-bd26-59131318e6a2              |
|                       | memory.usage: b768ec46-5e49-4d9a-b00d-004f610c152d                |
|                       | memory: 1a4e720a-2151-4265-96cf-4daf633611b2                      |
|                       | vcpus: 68654bc0-8275-4690-9433-27fe4a3aef9e                       |
| original_resource_id  | f0a62c20-2304-4c8c-aaf5-f5bc9d385b5f                              |
| project_id            | 8d077dbea6034e5aa45c0146d1feac5f                                  |
| revision_end          | None                                                              |
| revision_start        | 2021-11-09T10:00:46.241527+00:00                                  |
| started_at            | 2021-11-09T09:29:12.842149+00:00                                  |
| type                  | instance                                                          |
| user_id               | 65bfeb6cc8ec4df4a3d53550f7e99a5a                                  |
+-----------------------+-------------------------------------------------------------------+
```

This list shows the metrics associated with the instance.

You are done here.

### Checking if ceilometer is running

```
$ ssh controller-0 -l root
$ podman ps --format "{{.Names}} {{.Status}}" | grep ceilometer
ceilometer_agent_central Up 2 hours ago
ceilometer_agent_notification Up 2 hours ago
```

On compute nodes, there should be ceilometer_agent_compute running

```
$ podman ps --format "{{.Names}} {{.Status}}" | grep ceilometer
ceilometer_agent_compute Up 2 hours ago
```

The metrics are being sent from ceilometer to a remote defined in `/var/lib/config-data/puppet-generated/ceilometer/etc/ceilometer/pipeline.yaml`, which may look similar to the following file

```
---
sources:
    - name: meter_source
      meters:
          - "*"
      sinks:
          - meter_sink
sinks:
    - name: meter_sink
      publishers:
          - gnocchi://?filter_project=service&archive_policy=ceilometer-high-rate
          - notifier://172.17.1.40:5666/?driver=amqp&topic=metering

```
In this case, data is sent to both STF and Gnocchi. Next step is to check if there are any errors happening
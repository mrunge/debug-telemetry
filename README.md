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

The metrics are being sent from ceilometer to a remote defined in 
`/var/lib/config-data/puppet-generated/ceilometer/etc/ceilometer/pipeline.yaml`
, which may look similar to the following file

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
In this case, data is sent to both STF and Gnocchi. Next step is to check 
if there are any errors happening. On controllers and computes, ceilometer 
logs are found in `/var/log/containers/ceilometer/`. 

The `agent-notification.log` shows logs from publishing data, as well as
errors if sending out metrics or logs fails for some reason.

If there are any errors in the log file, it is likely that metrics are not
being delivered to the remote.

```
2021-11-16 07:01:07.063 16 ERROR oslo_messaging.notify.messaging   File "/usr/lib/python3.6/site-packages/oslo_messaging/transport.py", line 136, in _send_notification
2021-11-16 07:01:07.063 16 ERROR oslo_messaging.notify.messaging     retry=retry)
2021-11-16 07:01:07.063 16 ERROR oslo_messaging.notify.messaging   File "/usr/lib/python3.6/site-packages/oslo_messaging/_drivers/impl_amqp1.py", line 295, in wrap
2021-11-16 07:01:07.063 16 ERROR oslo_messaging.notify.messaging     return func(self, *args, **kws)
2021-11-16 07:01:07.063 16 ERROR oslo_messaging.notify.messaging   File "/usr/lib/python3.6/site-packages/oslo_messaging/_drivers/impl_amqp1.py", line 397, in send_notification
2021-11-16 07:01:07.063 16 ERROR oslo_messaging.notify.messaging     raise rc
2021-11-16 07:01:07.063 16 ERROR oslo_messaging.notify.messaging oslo_messaging.exceptions.MessageDeliveryFailure: Notify message sent to <Target topic=event.sample> failed: timed out
```

In this case, it failes to send messages to the STF instance. The following
example shows the gnocchi api not responding or not being accessible

```
2021-11-16 10:38:07.707 16 ERROR ceilometer.publisher.gnocchi [-] <html><body><h1>503 Service Unavailable</h1>
No server is available to handle this request.
</body></html>
 (HTTP 503): gnocchiclient.exceptions.ClientException: <html><body><h1>503 Service Unavailable</h1>
```

For more gnocchi debugging, see the gnocchi section.

### Gnocchi

Gnocchi sits on controller nodes and consists of three separate containers,
gnocchi_metricd, gnocchi_statsd, and gnocchi_api. The latter is for the
interaction with the outside world, such as ingesting metrics or returning
measurements.

Gnocchi metricd are used for re-calculating metrics, downsampling for lower
granularity, etc. Gnocchi logfiles are found under `/var/log/containers/gnocchi`
and the gnocchi API is hooked into httpd, thus the logfiles are
stored under `/var/log/containers/httpd/gnocchi-api/`. The corresponding files
there are either `gnocchi_wsgi_access.log` or `gnocchi_wsgi_error.log`.

In the case from above (ceilometer section), where ceilometer could not
send metrics to gnocchi, one would also observe log output for the
gnocchi API.

### Retrieving metrics from Gnocchi

For a starter, let's see which resources there are.

```
openstack server list -c ID -c Name -c Status
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

To show which metrics are stored for the vm `foo-1` one would use the following
command

```
openstack metric resource show f0a62c20-2304-4c8c-aaf5-f5bc9d385b5f --max-width 75
+-----------------------+-------------------------------------------------+
| Field                 | Value                                           |
+-----------------------+-------------------------------------------------+
| created_by_project_id | 6a180caa64894f04b1d04aeed1cb920e                |
| created_by_user_id    | 39d9e30374a74fe8b58dee9e1dcd7382                |
| creator               | 39d9e30374a74fe8b58dee9e1dcd7382:6a180caa64894f |
|                       | 04b1d04aeed1cb920e                              |
| ended_at              | None                                            |
| id                    | f0a62c20-2304-4c8c-aaf5-f5bc9d385b5f            |
| metrics               | cpu: fe84c113-f98d-42ee-84fd-bdf360842bdb       |
|                       | disk.ephemeral.size:                            |
|                       | ad79f268-5f56-4ff8-8ece-d1f170621217            |
|                       | disk.root.size:                                 |
|                       | 6e021f8c-ead0-46e4-bd26-59131318e6a2            |
|                       | memory.usage:                                   |
|                       | b768ec46-5e49-4d9a-b00d-004f610c152d            |
|                       | memory: 1a4e720a-2151-4265-96cf-4daf633611b2    |
|                       | vcpus: 68654bc0-8275-4690-9433-27fe4a3aef9e     |
| original_resource_id  | f0a62c20-2304-4c8c-aaf5-f5bc9d385b5f            |
| project_id            | 8d077dbea6034e5aa45c0146d1feac5f                |
| revision_end          | None                                            |
| revision_start        | 2021-11-09T10:00:46.241527+00:00                |
| started_at            | 2021-11-09T09:29:12.842149+00:00                |
| type                  | instance                                        |
| user_id               | 65bfeb6cc8ec4df4a3d53550f7e99a5a                |
+-----------------------+-------------------------------------------------+
```

To view the memory usage between Nov 18 2021 17:00 UTC and 17:05 UTC, one
would issue this command:

```
openstack metric measures show --start 2021-11-18T17:00:00 \
                               --stop 2021-11-18T17:05:00 \
                               --aggregation mean 
                               b768ec46-5e49-4d9a-b00d-004f610c152d

+---------------------------+-------------+-------------+
| timestamp                 | granularity |       value |
+---------------------------+-------------+-------------+
| 2021-11-18T17:00:00+00:00 |      3600.0 | 28.87890625 |
| 2021-11-18T17:00:00+00:00 |        60.0 | 28.87890625 |
| 2021-11-18T17:01:00+00:00 |        60.0 | 28.87890625 |
| 2021-11-18T17:02:00+00:00 |        60.0 | 28.87890625 |
| 2021-11-18T17:03:00+00:00 |        60.0 | 28.87890625 |
| 2021-11-18T17:04:00+00:00 |        60.0 | 28.87890625 |
| 2021-11-18T17:00:14+00:00 |         1.0 | 28.87890625 |
| 2021-11-18T17:00:44+00:00 |         1.0 | 28.87890625 |
| 2021-11-18T17:01:14+00:00 |         1.0 | 28.87890625 |
| 2021-11-18T17:01:44+00:00 |         1.0 | 28.87890625 |
| 2021-11-18T17:02:14+00:00 |         1.0 | 28.87890625 |
| 2021-11-18T17:02:44+00:00 |         1.0 | 28.87890625 |
| 2021-11-18T17:03:14+00:00 |         1.0 | 28.87890625 |
| 2021-11-18T17:03:44+00:00 |         1.0 | 28.87890625 |
| 2021-11-18T17:04:14+00:00 |         1.0 | 28.87890625 |
| 2021-11-18T17:04:44+00:00 |         1.0 | 28.87890625 |
+---------------------------+-------------+-------------+
```

This shows, the data is available with granularity 3600, 60 and 1 sec. The memory usage does
not change over the time, that's why the values don't change.

More info about the metric can be actually listed by using

```
openstack metric show --resource-id f0a62c20-2304-4c8c-aaf5-f5bc9d385b5f \
              memory.usage \
              --max-width 75

+--------------------------------+----------------------------------------+
| Field                          | Value                                  |
+--------------------------------+----------------------------------------+
| archive_policy/name            | ceilometer-high-rate                   |
| creator                        | 39d9e30374a74fe8b58dee9e1dcd7382:6a180 |
|                                | caa64894f04b1d04aeed1cb920e            |
| id                             | b768ec46-5e49-4d9a-b00d-004f610c152d   |
| name                           | memory.usage                           |
| resource/created_by_project_id | 6a180caa64894f04b1d04aeed1cb920e       |
| resource/created_by_user_id    | 39d9e30374a74fe8b58dee9e1dcd7382       |
| resource/creator               | 39d9e30374a74fe8b58dee9e1dcd7382:6a180 |
|                                | caa64894f04b1d04aeed1cb920e            |
| resource/ended_at              | None                                   |
| resource/id                    | f0a62c20-2304-4c8c-aaf5-f5bc9d385b5f   |
| resource/original_resource_id  | f0a62c20-2304-4c8c-aaf5-f5bc9d385b5f   |
| resource/project_id            | 8d077dbea6034e5aa45c0146d1feac5f       |
| resource/revision_end          | None                                   |
| resource/revision_start        | 2021-11-09T10:00:46.241527+00:00       |
| resource/started_at            | 2021-11-09T09:29:12.842149+00:00       |
| resource/type                  | instance                               |
| resource/user_id               | 65bfeb6cc8ec4df4a3d53550f7e99a5a       |
| unit                           | MB                                     |
+--------------------------------+----------------------------------------+
```

It shows in this case, the used archive policy is ceilometer-high-rate.

```
openstack metric archive-policy show ceilometer-high-rate --max-width 75
+---------------------+---------------------------------------------------+
| Field               | Value                                             |
+---------------------+---------------------------------------------------+
| aggregation_methods | mean, rate:mean                                   |
| back_window         | 0                                                 |
| definition          | - timespan: 1:00:00, granularity: 0:00:01,        |
|                     | points: 3600                                      |
|                     | - timespan: 1 day, 0:00:00, granularity: 0:01:00, |
|                     | points: 1440                                      |
|                     | - timespan: 365 days, 0:00:00, granularity:       |
|                     | 1:00:00, points: 8760                             |
| name                | ceilometer-high-rate                              |
+---------------------+---------------------------------------------------+
```

That means, in this case, the aggregation methods one could use for querying
the metrics are just mean and rate:mean. Other methods could include min or max.

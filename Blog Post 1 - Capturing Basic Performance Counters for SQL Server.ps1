<#
Title:          Blog Post 1 - Capturing Basic Performance Counters for SQL Server
Author:         Bill Ramos, DB Best Technologies
Published:      12/31/2019
Description:
                This script captures disk system based performance counters that provide data used to understand the 
                current performance of a SQL Server instance needed to optimize EBS volumes for similar performance
                with lower storage costs.

                This version of the script runs for a specific amount of time in a loop on the server your are testing
                and writes the results to the C:\Temp drive. 
#>

##############################################################
# 1. Setup the variables for the run and get the computer name
############################################################## 
$Task = "Trial_1"   # Unique identifier for the test run. Used as part of the output file name for the results.
$perfmon_outfile = "C:\Temp\Task-$($Task)-PerfMon-Capture.csv"  # Name for the output file.

# Specify the number of seconds to colect the data and how often to check 
$Timeout = 600      # Defines the number of seconds to capture the counters. Ex. 600 = 10 mins, 3600 = 1 hr, 28800 = 8 hr
$CheckEvery = 60    # Defines the number of seconds to wait before checking again


########################################################
# 2. Create an array of the counters you want to collect
########################################################

<# 
The objective for the performance collection is to make sure that you have suffcient IOPS and MB/s for your target EC2 instance to support your existing systems while keeping in mind that you aren't limited by memory and CPU.

This set of counters represents a smaller set that DB Best normally collects as part of our managed services. There is lots of guidance from SQL Server experts on routine counters to capture. For example, I found this article useful for the essentials - http://www.appadmintools.com/documents/windows-performance-counters-explained/. In addtion, this post goes into great detail on what disk counters mean - https://blogs.technet.microsoft.com/askcore/2012/03/16/windows-performance-monitor-disk-counters-explained/.

However, I haven't found any published tips on the counters need to optimize storage to improve performance or help reduce the cost of storage while maintaining similar performance. 

In some cases, I use the * (wildcard) to simplify collection. This first blog post focuses on the essential counters needed for the disk optimization process. Also, using just the counters you need dramatically decreases the size of the resulting file for faster processing by Power BI. 

I've added comments after each counters as to why I felt the counter was useful. I'll group the counters into three categories: CPU, Memory, and Disk. I left off Network since my process for optimizing disk performance assumes that the network latency is not a bottleneck.

I'm also assuming that for the initial benchmark that the application database under test has seperate drives for the database (E:) and log files (L:), tempdb (T:), and the backup files (G:). If you happen to have the Log files on the same drive as the Data files, there are SQL Server:Database counters that can get the IOPS and B/s values.

However, I'm not including optimization of the backup and restore process. The process that I'm using can be used to optimize the backup drives as well. But, that's for a later blog. 

#> 
$Counters = @(
<#
CPU Categories
By using the CPU performance, we can determine if the CPU ended up being a bottleneck. In the case of a CPU bottleneck, if you know that your queries are optimized, then you might want to consider more vCPUs for your EC2 instance. Otherwise, look for the standard culprits like missing indexes. Looking at sys.dm_exec_query_stats is a good place to start. Also, new features like Query Store and the open source version of Open Query Store (https://github.com/OpenQueryStore/OpenQueryStore) can help in identifying issues with specific queries. 
#>
# Processor
  "\Processor(_Total)\% Processor Time"          # Looking at the combined CPU usage provides a good way to identify patterns to investigate
, "\Processor(*)\% Processor Time"               # This looks at all vCPUs. This is helpful as well to see if you can reduce vCPUs.
, "\Processor(_total)\% Privileged Time"         # % time on kernal operations. If value is high, check AWS for EC2 driver patches.
, "\Processor(_total)\% User Time" # % time spent on applications like SQL Server.

# \SQLServer:Workload Group Stats
, "\SQLServer:Workload Group Stats(*)\CPU usage %"      # % time SQL Server is spending on a specific Workload Group like default. If your are
                                                                    # using Resource Governor with CPU limits on groups, look for bottlenecks and adjust.
<#
Memory Counter Categories
The memory counters for Windows and SQL Server will give you an idea if memory is a bottleneck. If SQL Server is consuming all of the server's available memory, it can result in an increase of smaller IO reads and writes placing pressure on disk IO. Another symptom is the CPU % Processor time could drop because the CPU is waiting for IO. If this is the case, you might want to consider an EC2 instance with a larger Memory to vCPU ratio. The AWS Optimized CPU feature is a great way to do this by using a larger EC2 instance, but use less vCPUs to keep your SQL Server licence allocation down.
#>
# - Memory
, "\Memory\Available Kbytes"                     # The Kbytes counter aligns nicely woth SQL Server's (KB) scale.
, "\Memory\Committed Bytes"                      # If Committed bytes is greater than physical memory, then more RAM will help. It means your paging memory to disk.

# - Paging File
, "\Paging File(_Total)\% Usage"                 # This is not really a Memory counter. A high value for the % Usage would indicate memory pressure.

# - SQL Server:Memory Manager
, "\SQLServer:Memory Manager\Database Cache Memory (KB)" # This is basically the buffer pool. You can use sys.dm_os_buffer_descriptors to see top DB consumers.
, "\SQLServer:Memory Manager\Free Memory (KB)"           # Represents the amount of memory SQL Server has available to use
, "\SQLServer:Memory Manager\Target Server Memory (KB)"  # The amount of memory that SQL Server thinks it needs at the time
, "\SQLServer:Memory Manager\Total Server Memory (KB)"   # An approximation of how much the database engine is using.
                                                                    # NOTE: Over time, if Total Server Memory never gets close to the server's available memory, 
                                                                    # you might want to consider using an less expensive EC2 instance with less memory.

<#
Disk Counter Categories
- LogicalDisk
By using _Total, we are essentially looking at the totals for all drives supporting the server. This includes the Local SSD that I typically recommend for TempDB. The Local SSD IOPS used are not restricted my the Max IOPS for the EC2 instance.

- PhysicalDisk
By using (* *), we can capture all the physical disks. When striping drives with Windows Storage Spaces or Disk Manager, you get a sum for all underlying drives that make up the disk volume. Keep in mind that AWS IOPS ratings are based on a 16k block size for reads and writes. If SQL Server is making a large number of 64k read operations trying to load data into the database cache when there is no memory pressure, you might see less IOPS because of the larger data block. However, under memory pressure, SQL Server may read and write data in smaller blocks.
#>
# IOPS counters - Reported as the average of the interval where the interval is greater than 1 second.
, "\LogicalDisk(_Total)\Disk Reads/sec"          # Read operations where SQL Server has to load data into buffer pool
, "\LogicalDisk(_Total)\Disk Writes/sec"         # Write operations where SQL Server has to harden data to disk
, "\LogicalDisk(_Total)\Disk Transfers/sec"      # Tranfers (AKA IOPS) is approximately the sum of the Read/sec and Writes/sec

# Throughput counters - Bytes/sec - Reported as the average of the interval where the interval is greater than 1 second.
, "\LogicalDisk(_Total)\Disk Read Bytes/sec"     # Read throughput
, "\LogicalDisk(_Total)\Disk Write Bytes/sec"    # Write throughput
, "\LogicalDisk(_Total)\Disk Bytes/sec"          # Total throughput

# Block sizes for IO - Reported as an average for the interval. These are useful to look at over time to see the block sizes SQL Server is using.
, "\LogicalDisk(_Total)\Avg. Disk Bytes/Read"    # Read IO block size
, "\LogicalDisk(_Total)\Avg. Disk Bytes/Write"   # Write IO block size
, "\LogicalDisk(_Total)\Avg. Disk Bytes/Transfer"# Raed + Write IO block size

# Latency counter - Avg. Disk sec/Transfer represents IO latency. 
#This really isn't needed for the optimization, but it does verify volume configuration.
, "\LogicalDisk(_Total)\Avg. Disk sec/Transfer"  # For gp2 drives, this value is generally around .001 sec (1 ms) or less. 
                                                            # SQL Seerver sys.dm_io_virtual_file_stats calls this io_stall_read/write

# Physical counters - We collect the same counters as the LogicalDisk, but the values are reported by drive letter. Same comments above apply.
, "\PhysicalDisk(* *)\Disk Reads/sec"
, "\PhysicalDisk(* *)\Disk Writes/sec"
, "\PhysicalDisk(* *)\Disk Transfers/sec"
, "\PhysicalDisk(* *)\Disk Read Bytes/sec"
, "\PhysicalDisk(* *)\Disk Write Bytes/sec"
, "\PhysicalDisk(* *)\Disk Bytes/sec"
, "\PhysicalDisk(* *)\Avg. Disk Bytes/Read" 
, "\PhysicalDisk(* *)\Avg. Disk Bytes/Write" 
, "\PhysicalDisk(* *)\Avg. Disk Bytes/Transfer"
, "\PhysicalDisk(* *)\Avg. Disk sec/Transfer"

# SQL Server:Databases - We can collect specific counters for the log operations if we want to later move the database log files to another volume.
#                        These values are used for EBS volume optimization for the Log volume.
, "\SQLServer:Databases(*)\Log Flushes/sec"          # Shows Write IOPS for all database log files.
, "\SQLServer:Databases(*)\Log Bytes Flushed/sec"    # Shows Write Bytes/sec for all database log files.

)

######################################################
# 3. Get the first sample before starting the workload
######################################################
Get-Counter -Counter $Counters | ForEach-Object {
    $_.CounterSamples | ForEach-Object {
        [pscustomobject]@{
            "Task ID" = $Task
             "Event Date Time (UTC)" = $_.TimeStamp
             "Performance Counter" = $_.Path
             Value = $_.CookedValue
        }
    }
} | Export-Csv -Path "$perfmon_outfile" -NoTypeInformation -Append

##############################################
# 4. Start the time and then collect counters.
##############################################

# Start the timer using the Stopwatch Class within the .NET Framework
# https://docs.microsoft.com/en-us/dotnet/api/system.diagnostics.stopwatch?view=netframework-4.8
$timersql = [Diagnostics.Stopwatch]::StartNew()

while ( $timersql.Elapsed.TotalSeconds -lt $Timeout )
{
    Write-Host "Time remaining = $( $Timeout - $timersql.Elapsed.TotalSeconds )"
    # Time to sleep based on the value for $CheckEvery in seconds. 
    # The wait is done here to make sure that the inital performance counters are captured. 
    Start-Sleep -Seconds $CheckEvery

    # The wait is over, get the next set of performance counters
    Get-Counter -Counter $Counters | ForEach-Object {
        $_.CounterSamples | ForEach-Object {
            [pscustomobject]@{
                "Task ID" = $Task
                "Event Date Time (UTC)" = $_.TimeStamp
                "Performance Counter" = $_.Path
                Value = $_.CookedValue
            }
        }
    } | Export-Csv -Path "$perfmon_outfile" -NoTypeInformation -Append

}

# That's it!
Write-Host "Go to the file $($perfmon_outfile) to see the results."

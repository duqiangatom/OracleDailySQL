1.--->Session - Event - Blocker - process


/*
   SID USERNAME   MACHINE         MODULE                              EVENT                          SQL_ID          EXEC_GETS OBJECT_ID HOLDER     FINAL      SECON PARAM                            SPID     PGA_USE SQL_TEXT
------ ---------- --------------- ----------------------------------- ------------------------------ --------------- --------- --------- ---------- ---------- ----- ------------------------------ -------- ------- ------------------------------
  1561 SYS        hkl25077556     sqlplus@hkl25077556 (TNS V1-V3)     SQL*Net message to client      6w0kb7h1r1mmz          14      5214 _          _          0     1650815232_1_0                   3045184        5 select a.sid,        a.usernam
  1646 SYS        hkl25077556     sqlplus@hkl25077556 (TNS V1-V3)     PGA memory operation           asqd313zz78gz       28559       259 _          _          80    131072_1_0               3043632        8 select count(*) from dba_objec
*/




set linesize 260
set pagesize 1000
col sid for 99999
col spid for a8
col event for a30
col module for a35
col machine for a15
col username for a10
col holder for a10
col final for a10
col sql_id for a15
col exec_gets for 99999999
col seconds for a5
col object_id for 999999
col param for a30
col sql_text for a30
col PGA_USE for 9999
alter session set nls_date_format='yyyy-mm-dd hh24:mi:ss';
select a.sid,
       a.username,
       a.machine,
       a.module,
       a.event,
       a.sql_id,
       round(decode(c.executions,0,buffer_gets,buffer_gets/executions)) exec_gets,
       a.ROW_WAIT_OBJ# object_id,
       a.BLOCKING_INSTANCE||'_'||a.blocking_session  holder,
       a.FINAL_BLOCKING_INSTANCE||'_'||a.FINAL_BLOCKING_SESSION final,
       to_char(LAST_CALL_ET) seconds,
       a.p1 || '_' || a.p2 || '_' || a.p3 param,
       b.spid,
       trunc(b.PGA_USED_MEM / 1024 / 1024,2) as PGA_USE,
       substr(c.sql_text,0,30) sql_text
  from v$session a, v$process b,v$sql c
 where a.paddr = b.addr(+)
   and a.status = 'ACTIVE'
   and not (a.type = 'BACKGROUND' and a.state = 'WAITING' and
        a.wait_class = 'Idle')
   and a.sql_id=c.sql_id(+)
   and a.sql_child_number=c.CHILD_NUMBER(+)
 order by a.sql_id, a.machine
/	

2.---> SQLs(>5s) - ExecuteTime - ElapseTime = CPU Time + IO Time + Others

/*
SID_SERIAL      USERNAME             SQL_ID          SQL_PLAN_HASH_VALUE SQL_EXEC_START      ELAPSE_SEC      CPU_S USER_IO_W_S CONCURRENCY_W_S STATUS              SQL_TEXT
--------------- -------------------- --------------- ------------------- ------------------- ---------- ---------- ----------- --------------- ------------------- ------------------------------
1646,57607      SYS                  asqd313zz78gz             691226011 2022-09-23 05:55:10     103.24      75.08           0               0 EXECUTING           select count(*) from dba_objec
*/


BREAK ON sql_id ON sql_plan_hash_value SKIP 1

SET LINES 500
SET PAGES 10000
COLUMN sid_serial FORMAT a15
COLUMN username FORMAT A20 
COLUMN sql_text FORMAT A30 

SELECT
    sid  || ','    || session_serial#   AS sid_serial,
    username,
    sql_id,
    sql_plan_hash_value,
    sql_exec_start,
    --sql_exec_id,
    round(elapsed_time / 1000000, 2)         AS elapse_sec,
    round(cpu_time / 1000000,2)              AS cpu_s,
    round(USER_IO_WAIT_TIME/1000000,2)  as USER_IO_W_s,
    round(CONCURRENCY_WAIT_TIME/1000000,2)  as CONCURRENCY_W_s,
    status,
    substr(sql_text, 1, 30)                 AS sql_text
FROM
    gv$sql_monitor
WHERE module NOT LIKE '%emagent%'
        AND sql_exec_start > ( sysdate - 1 / 24 )
        AND status NOT LIKE 'DONE%' 
        AND   elapsed_time > 5000000    
order by sql_id, sql_exec_start;


3. ---> SQL Plan -  by SQL_ID  --SQL_MONITOR OR SQL_HC report

select plan_table_output from table(dbms_xplan.display_cursor('asqd313zz78gz'));


4.  --SQL - multiple Plan & execute - history 

/*
---SQL elapse time for each execution with 1 Hrs(ASH精确到秒 [1s/sample]，longer than 5s)


SQL_ID          SQL_EXEC_ID SQL_EXEC_START      SQL_PLAN_HASH_VALUE ASH_ELAPSE_TIME_SEC
--------------- ----------- ------------------- ------------------- -------------------
asqd313zz78gz      16777224 2022-09-23 05:48:31           691226011                 125
                   16777225 2022-09-23 05:55:10                                     134
*/


break on sql_id on SQL_PLAN_HASH_VALUE skip 1
set lines 400
set pages 10000

select
        sql_id,
        sql_exec_id,
        SQL_EXEC_START,
        SQL_PLAN_HASH_VALUE,
        max(tm) ASH_Elapse_time_sec
   from ( select
              sql_id,
              sql_exec_id,
              SQL_EXEC_START,
              SQL_PLAN_HASH_VALUE,
              ((cast(sample_time  as date)) -
              (cast(sql_exec_start as date))) * (3600*24) tm
           from
              v$active_session_history
           where sql_exec_id is not null and sample_time > (sysdate - 1/24) 
            and sql_id='asqd313zz78gz'
         )
group by sql_id,sql_exec_id,SQL_EXEC_START,SQL_PLAN_HASH_VALUE 
having max(tm)>5
order by SQL_id,SQL_EXEC_START;


5.  --SQL - Wait Event class - history 


/*
   TOP SQL from v$active_session_history

SQL_ID           PLAN_HASH TYPE           CPU WAIT_Other      IO      TOTAL
--------------- ---------- ---------- ------- ---------- ------- ----------
asqd313zz78gz    691226011 SELECT        1077          0       0       1077
                         0 SELECT         125          0       0        125
*/

col type for a10
col "CPU" for 999999
col "IO" for 999999

select * from (
select
     ash.SQL_ID , ash.SQL_PLAN_HASH_VALUE Plan_hash, sql_exec_start, aud.name type,
     sum(decode(ash.session_state,'ON CPU',1,0))     "CPU",
     sum(decode(ash.session_state,'WAITING',1,0))    -
     sum(decode(ash.session_state,'WAITING', decode(wait_class, 'User I/O',1,0),0))    "WAIT_Other" ,
     sum(decode(ash.session_state,'WAITING', decode(wait_class, 'User I/O',1,0),0))    "IO" ,
     sum(decode(ash.session_state,'ON CPU',1,1))     "TOTAL"
from v$active_session_history ash,
     audit_actions aud
where SQL_ID = '&SQL_ID'
   -- and ash.dbid=DBID
   and ash.sql_opcode=aud.action
   -- and ash.sample_time > sysdate - &minutes /( 60*24)
group by sql_id, SQL_PLAN_HASH_VALUE,sql_exec_start , aud.name
order by sum(decode(session_state,'ON CPU',1,1))   desc
) where  rownum < 10
/



Appendix:

---3.1.Generate SQL Mintor Report for SQL ID(SQL PLAN+ Resource used details):

SET LONG 1000000
SET LONGCHUNKSIZE 1000000
SET LINESIZE 1000
SET PAGESIZE 0
SET TRIM ON
SET TRIMSPOOL ON
SET ECHO OFF
SET FEEDBACK OFF

SPOOL report_sql_monitor.html
SELECT DBMS_SQLTUNE.report_sql_monitor(
  sql_id       => 'c0ym21ns5twt0',
  type         => 'ACTIVE',
  report_level => 'ALL') AS report
FROM dual;
SPOOL OFF


---or 3.2.Generate SQL Mintor Report for SQL can't found in 1(SQL flushed out of Mem already)

----DBA_HIST_REPORTS.KEY1 is the SQL_ID for the statement
----DBA_HIST_REPORTSKEY2 is the SQL execution_id for the statement

--A.Get the report ID from AWR report dictionary DBA_HIST_REPORT

SELECT report_id  FROM dba_hist_reports
WHERE dbid = 1954845848  AND component_name = 'sqlmonitor'  AND report_name = 'main'
AND period_start_time BETWEEN  &date1 AND &date1
AND key1 = &sql_id;

----date1 format like: To_date('27/07/2017 11:15:00','DD/MM/YYYY HH:MI:SS')


--B.Once you have the REPORT_ID, use the PL/SQL function DBMS_AUTO_REPORT.REPORT_REPOSITORY_DETAIL to generate the SQL Monitor report below.

SET echo ON
SET trimspool ON
SET TRIM ON
SET pages 0
SET linesize 32767
SET LONG 10000000
SET longchunksize 1000000
spool old_sqlmon.html

SELECT dbms_auto_report.Report_repository_detail(rid=> &report_id, TYPE=> 'active')
FROM dual;
 
spool OFF

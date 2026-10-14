"""Offline control-flow tests. No Databricks account or database is contacted."""
import json, os, pathlib, subprocess, tempfile, unittest
SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'lakebase-demo.sh'
MOCK = r'''#!/usr/bin/env python3
import json,os,sys,pathlib
args=sys.argv[1:]; root=pathlib.Path(os.environ['MOCK_STATE']); mode=os.environ.get('MOCK_MODE','')
with (root/'calls').open('a') as f: f.write(json.dumps([pathlib.Path(sys.argv[0]).name,args])+'\n')
if pathlib.Path(sys.argv[0]).name=='psql':
 host=args[args.index('-h')+1]
 if '-f' in args:
  if mode=='sql-fail':sys.exit(3)
  print('seed complete');sys.exit()
 query=' '.join(args)
 if 'DELETE FROM' in query:
  if host=='source.example.com':sys.exit(90)
  if mode=='delete-fail':sys.exit(3)
  (root/'deleted').touch();print('DELETE 36')
 elif 'count(*) FROM public.inventory;' in query:
  print(0 if host!='source.example.com' and (root/'deleted').exists() else 36)
 else: print('connected')
 sys.exit()
if args==['--version']:print('Databricks CLI vMOCK');sys.exit()
assert args[:2]==['--profile','lakebase-demo']
a=args[2:];cmd=a[1] if len(a)>1 else ''
if a[:2]==['current-user','me']:print(json.dumps({'userName':'demo@example.com'}));sys.exit()
if a[:2]==['auth','login']:sys.exit()
if cmd=='get-project':print(json.dumps({'name':a[2]}))
elif cmd=='list-projects':print('[]')
elif cmd=='create-project':print('{}')
elif cmd=='list-branches':
 rows=[{'name':'projects/demo/branches/source-id','status':{'default':True}}]
 if mode=='no-default':rows=[]
 print(json.dumps(rows if mode=='array' else {'branches':rows}))
elif cmd=='get-branch':print(json.dumps({'name':a[2]}))
elif cmd=='list-endpoints':
 rows=[{'name':a[2]+'/endpoints/primary','status':{'endpoint_type':'ENDPOINT_TYPE_READ_WRITE'}}]
 if mode=='ambiguous':rows=rows*2
 print(json.dumps(rows if mode=='array' else {'endpoints':rows}))
elif cmd=='get-endpoint':
 host='source.example.com' if '/source-id/' in a[2] or mode=='same-host' else 'child.example.com'
 print(json.dumps({'name':a[2], 'status':{'hosts':{'host':host}}}))
elif cmd=='generate-database-credential':
 print(json.dumps({} if mode=='no-token' else {'token':'MOCK_SECRET_TOKEN'}))
elif cmd=='create-branch':
 if '--help' in a:print('--ttl duration');sys.exit()
 if mode=='create-fail':sys.exit(1)
 assert '--ttl' in a and a[a.index('--ttl')+1]=='1h'
 print('{}')
elif cmd=='delete-branch':
 if mode=='cleanup-fail':sys.exit(1)
 print('{}')
else:raise RuntimeError(a)
'''
class WorkflowTests(unittest.TestCase):
 def run_action(self,action,mode='',confirmation=''):
  with tempfile.TemporaryDirectory() as d:
   root=pathlib.Path(d); bin=root/'bin';bin.mkdir()
   for tool in ['databricks','psql']:
    f=bin/tool;f.write_text(MOCK);f.chmod(0o755)
   (root/'schema.sql').write_text('-- fixture');(root/'seed.sql').write_text('-- fixture')
   env=os.environ.copy();env.update(PATH=str(bin)+':'+env['PATH'], MOCK_STATE=d,MOCK_MODE=mode,LAKEBASE_PROJECT_ID='demo',LAKEBASE_PROFILE='lakebase-demo',LAKEBASE_SQL_DIR=d)
   env.pop('LAKEBASE_BRANCH_ID',None);env.pop('LAKEBASE_DATABASE',None)
   result=subprocess.run(['bash',str(SCRIPT),action],input=confirmation,text=True,capture_output=True,env=env)
   calls=[json.loads(x) for x in (root/'calls').read_text().splitlines()] if (root/'calls').exists() else []
   self.assertNotIn('MOCK_SECRET_TOKEN',result.stdout+result.stderr)
   return result,calls
 def test_help(self):
  r,c=self.run_action('help');self.assertEqual(r.returncode,0);self.assertEqual(c,[])
 def test_status(self):
  r,c=self.run_action('status');self.assertEqual(r.returncode,0);self.assertIn('source-id',r.stderr)
 def test_connect_array(self):
  r,c=self.run_action('connect','array');self.assertEqual(r.returncode,0);self.assertIn('connected',r.stdout)
 def test_no_default_stops(self):
  r,c=self.run_action('seed','no-default');self.assertNotEqual(r.returncode,0);self.assertFalse(any(x[0]=='psql' for x in c))
 def test_ambiguous_endpoint_stops(self):
  r,c=self.run_action('seed','ambiguous');self.assertNotEqual(r.returncode,0);self.assertFalse(any(x[0]=='psql' for x in c))
 def test_cancel_seed(self):
  r,c=self.run_action('seed',confirmation='no\n');self.assertNotEqual(r.returncode,0);self.assertFalse(any(x[0]=='psql' for x in c))
 def test_seed_atomic(self):
  r,c=self.run_action('seed',confirmation='RESET projects/demo/branches/source-id/databricks_postgres\n')
  self.assertEqual(r.returncode,0,r.stderr)
  a=next(x[1] for x in c if x[0]=='psql');self.assertIn('--single-transaction',a);self.assertIn('ON_ERROR_STOP=1',a);self.assertEqual(a.count('-f'),2)
 def test_sql_failure_stops(self):
  r,c=self.run_action('seed','sql-fail','RESET projects/demo/branches/source-id/databricks_postgres\n')
  self.assertNotEqual(r.returncode,0);self.assertEqual(sum(x[0]=='psql' for x in c),1)
 def test_missing_token(self):
  r,c=self.run_action('connect','no-token');self.assertNotEqual(r.returncode,0);self.assertFalse(any(x[0]=='psql' for x in c))
 def test_branch_success_cleanup(self):
  r,c=self.run_action('branch-demo');self.assertEqual(r.returncode,0,r.stderr);self.assertIn('PASS:',r.stderr)
  deletes=[x for x in c if 'delete-branch' in x[1]];self.assertEqual(len(deletes),1);self.assertIn('/cli-demo-',deletes[0][1][4])
 def test_alias_host_stops_delete(self):
  r,c=self.run_action('branch-demo','same-host');self.assertNotEqual(r.returncode,0)
  self.assertFalse(any('DELETE FROM' in ' '.join(x[1]) for x in c));self.assertTrue(any('delete-branch' in x[1] for x in c))
 def test_failed_creation_not_deleted(self):
  r,c=self.run_action('branch-demo','create-fail');self.assertNotEqual(r.returncode,0);self.assertFalse(any('delete-branch' in x[1] for x in c))
 def test_failed_sql_still_cleans(self):
  r,c=self.run_action('branch-demo','delete-fail');self.assertNotEqual(r.returncode,0);self.assertTrue(any('delete-branch' in x[1] for x in c))
 def test_failed_cleanup_reported(self):
  r,c=self.run_action('branch-demo','cleanup-fail');self.assertNotEqual(r.returncode,0);self.assertIn('Cleanup failed',r.stderr)
if __name__=='__main__':unittest.main(verbosity=2)

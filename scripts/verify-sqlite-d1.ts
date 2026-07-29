import { Database } from "bun:sqlite";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { buildVerification, compareVerification } from "./lib/d1-ledger-verify";
const args=parse(Bun.argv.slice(2));
const source=verification(resolve(args.sqlite));
if(args.output) await Bun.write(resolve(args.output),JSON.stringify(source,null,2)+"\n"); else if(!args.destinationManifest&&!args.destinationSql) console.log(JSON.stringify(source,null,2));
let target;
if(args.destinationManifest) target=await Bun.file(resolve(args.destinationManifest)).json();
if(args.destinationSql){const dir=await mkdtemp(`${tmpdir()}/howmuch-d1-verify-`); try {const path=resolve(dir,"destination.sqlite"); const db=new Database(path,{create:true,strict:true}); try {db.exec(await Bun.file(resolve(args.destinationSql)).text()); db.exec("BEGIN"); target=buildVerification(db); db.exec("ROLLBACK");} finally {if(db.inTransaction)db.exec("ROLLBACK");db.close();}} finally {await rm(dir,{recursive:true,force:true});}}
if(target){const differences=compareVerification(source,target); if(differences.length){console.error(differences.join("\n"));process.exitCode=1;}else console.error("Source and destination verification manifests match.");}
function verification(path:string){const db=new Database(path,{readonly:true,strict:true});try{db.exec("BEGIN");const result=buildVerification(db);db.exec("ROLLBACK");return result;}finally{if(db.inTransaction)db.exec("ROLLBACK");db.close();}}
function parse(argv:string[]){const out:{sqlite:string;output?:string;destinationManifest?:string;destinationSql?:string}={sqlite:"data/howmuch-real.sqlite"}; const names:Record<string,keyof typeof out>={"--sqlite":"sqlite","--output":"output","--destination-manifest":"destinationManifest","--destination-sql":"destinationSql"}; for(let i=0;i<argv.length;i++){const name=names[argv[i]!];const value=argv[i+1];if(!name||!value)throw new Error(`Unknown or incomplete argument ${argv[i]}`);(out as any)[name]=value;i++;}if(out.destinationManifest&&out.destinationSql)throw new Error("Choose either --destination-manifest or --destination-sql");return out;}

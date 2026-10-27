"""Exercise the shipped stdio server with the official Python MCP client."""
import asyncio
import hashlib
import json
import tempfile
import uuid
import sys
from pathlib import Path
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

ROOT = Path(__file__).resolve().parents[1]
async def main():
    with tempfile.TemporaryDirectory(dir=ROOT / ".build") as tmp:
        root = Path(tmp)
        meeting = root / "fixture"
        meeting.mkdir()
        mid = str(uuid.uuid4()).upper()
        metadata = dict(schemaVersion=2,id=mid,title="MCP 검증",startedAt="2026-10-27T00:00:00Z",status="completed",segments=[],audioChunks=[],warnings=[],audioFile="audio.m4a")
        (meeting / ".meeting.json").write_text(json.dumps(metadata))
        transcript = "# MCP 검증\n\n## 화자 A\n\n내일까지 테스트 결과를 확인하겠습니다.\n"
        (meeting / "transcript.md").write_text(transcript)
        (meeting / "audio.m4a").write_bytes(b"local-fixture")
        before = {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in meeting.iterdir()}
        params = StdioServerParameters(command=str(ROOT / ".build/release/MeetingRecorderMCP"), args=["--root", str(root)])
        async with stdio_client(params) as (read,write):
            async with ClientSession(read,write) as client:
                await client.initialize()
                tools = await client.list_tools()
                assert {t.name for t in tools.tools}=={"list_meetings","get_transcript","get_meeting_paths","save_summary"}
                async def call(name,args):
                    r = await client.call_tool(name,args)
                    return r, None if r.is_error else json.loads(r.content[0].text)
                _, rows = await call("list_meetings",{})
                assert rows[0]["meeting_id"]==mid
                _, data = await call("get_transcript",dict(meeting_id=mid))
                assert data["transcript"]==transcript
                _, paths = await call("get_meeting_paths",dict(meeting_id=mid))
                assert paths["summary"] is None and paths["audio"]==str(meeting/"audio.m4a")
                args = dict(meeting_id=mid,markdown="# 요약\n\n테스트 결과 확인. 담당자 미정.\n",expected_summary_sha256=data["summary_sha256"],transcript_sha256=data["transcript_sha256"])
                result,saved = await call("save_summary",args)
                assert not result.is_error and Path(saved["summary_path"]).read_text()==args["markdown"]
                result,_ = await call("save_summary",args)
                assert result.is_error, "stale summary overwrite must fail"
                _, updated = await call("get_transcript",dict(meeting_id=mid))
                args["expected_summary_sha256"] = updated["summary_sha256"]
                args["markdown"] = "# 수정 요약\n"
                result,_ = await call("save_summary",args)
                assert not result.is_error and len(list((meeting/".summary-history").glob("*.md")))==1
                args["expected_summary_sha256"] = hashlib.sha256((meeting/"summary.md").read_bytes()).hexdigest()
                (meeting/"transcript.md").write_text(transcript+"추가 수정\n")
                result,_ = await call("save_summary",args)
                assert result.is_error, "stale transcript must fail"
                (meeting/"transcript.md").write_text(transcript)
                for invalid in ["../../etc/passwd",str(uuid.uuid4())]:
                    result,_ = await call("get_transcript",dict(meeting_id=invalid))
                    assert result.is_error
                with tempfile.TemporaryDirectory() as outside:
                    target=Path(outside)/"secret.md"; target.write_text("secret")
                    (meeting/"summary.md").unlink(); (meeting/"summary.md").symlink_to(target)
                    result,_ = await call("get_transcript",dict(meeting_id=mid))
                    assert result.is_error and target.read_text()=="secret"
                (meeting/"summary.md").unlink()
                metadata["status"]="recording"
                (meeting/".meeting.json").write_text(json.dumps(metadata))
                args["expected_summary_sha256"]="missing"
                result,_ = await call("save_summary",args)
                assert result.is_error, "active meeting summary must fail"
                result,_ = await call("get_transcript",dict(meeting_id=mid))
                assert result.is_error, "active transcript must wait for finalization"
                result,_ = await call("get_meeting_paths",dict(meeting_id=mid))
                assert not result.is_error, "paths should remain available during recording"
                metadata["status"]="completed"
                (meeting/".meeting.json").write_text(json.dumps(metadata))
                prompts=await client.list_prompts(); assert prompts.prompts[0].name=="summarize_meeting"
                prompt=await client.get_prompt("summarize_meeting",arguments={"meeting_id":mid}); assert mid in prompt.messages[0].content.text
                for name,digest in before.items():
                    assert hashlib.sha256((meeting/name).read_bytes()).hexdigest()==digest
        print("PASS: official MCP client initialize/list/read/paths/summary round trip, history, stale hashes, invalid IDs, symlink boundary, prompts, original preservation")
async def installed():
    command = ROOT / "dist/Meeting Recorder.app/Contents/MacOS/MeetingRecorderMCP"
    async with stdio_client(StdioServerParameters(command=str(command))) as (read,write):
        async with ClientSession(read,write) as client:
            await client.initialize()
            tools=await client.list_tools()
            assert len(tools.tools)==4
            result=await client.call_tool("list_meetings",{})
            assert not result.is_error, result
            rows=json.loads(result.content[0].text)
            if rows:
                result=await client.call_tool("get_meeting_paths",dict(meeting_id=rows[0]["meeting_id"]))
                assert not result.is_error
                paths=json.loads(result.content[0].text)
                if len(sys.argv)>2: assert paths["root"]==str(Path(sys.argv[2]).absolute()), paths["root"]
            print("PASS bundled MCP: initialize, four tools, saved app preferences; meetings",len(rows))

asyncio.run(installed() if "--installed" in sys.argv else main())

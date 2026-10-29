import subprocess
r=float(open('rec_start.txt').read())
rows=[l.split() for l in open('scenes.txt')]
scenes=[(l[1],float(l[2])-r) for l in rows if l[0]=='SCENE']
end=[float(l[1])-r for l in rows if l[0]=='END'][0]
t0=scenes[0][1]-0.3; dur=end-t0+0.5
cmd=['ffmpeg','-v','error','-y','-ss',f'{t0:.3f}','-i','take.mp4']
for n,_ in scenes: cmd+=['-i',f'audio/{n}.mp3']
f=[f'[{i+1}:a]adelay={int((t-t0+0.15)*1000)}|{int((t-t0+0.15)*1000)}[a{i}]' for i,(n,t) in enumerate(scenes)]
f.append(''.join(f'[a{i}]' for i in range(len(scenes)))+'amix=inputs=%d:normalize=0,apad[aout]' % len(scenes))
f.append('[0:v]scale=1920:-2,tpad=stop_mode=clone:stop_duration=6,fps=30,format=yuv420p,fade=t=out:st=%.2f:d=0.6[vout]' % (dur-0.6))
cmd+=['-filter_complex',';'.join(f),'-map','[vout]','-map','[aout]','-t',f'{dur:.3f}','-c:v','libx264','-crf','20','-preset','medium','-c:a','aac','-b:a','160k','-movflags','+faststart','Projector_demo.mp4']
subprocess.run(cmd,check=True)
for n,t in scenes: print(n, round(t-t0,2))
print('END', round(end-t0,2))

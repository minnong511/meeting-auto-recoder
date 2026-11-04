from score import contains, edits, norm, sentences, summarize
# Korean syllables, spacing, decimal numbers and unlike quantities must be distinguished.
assert edits(norm('회의를 시작합니다.'),norm('회의 시작합니다'))==1
assert edits(norm('삼'),norm('3'))==1
assert contains(['75.6cm','칠십오점육센티미터'],'길이는 75.6 cm입니다.','numbers')
assert not contains(['75.6cm'],'175.6cm','numbers')
assert contains(['33만명'],'환자가. 33만 명입니다.','numbers')
assert not contains(['33만명'],'0.33만 명입니다.','numbers')
assert not contains(['1~3마리'],'13마리','numbers')
assert contains(['330000명'],'총 330,000명입니다','numbers')
assert not contains(['삼만명'],'십삼만 명','numbers')
assert sentences('7.5입니다. 네!')==2 and sentences('')==0
try:
    summarize({'samples':[{'id':'1'}]},[])
    raise AssertionError('did not reject missing sample')
except ValueError:
    pass

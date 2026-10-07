you are writing a lua script for total war warhammer3

use clean code, only add comments when necessary, the project should have no need for comments, function names should be enough

the api reference is inside $HOME\AppData\Roaming\FrodoWazEre\rpfm\config\tw_autogen\output\wh3

for battle related queries, battle_manager.lua file might be important

antipatterns to avoid: 

### Middleman

A → B → C

A calls B.foo()
B calls C.foo()
C does the actual work

### redundant object construction

I have an object that has a vector field Vector(x,y,z)
I need x,y
instead of using vector, I create myClass(x,y)

### known issues

math.huge does not exist, use ANIAN_MAX_INT_VALUE instead

### after changes
run .\MoveFilesToPack.ps1
always tell that you have done it
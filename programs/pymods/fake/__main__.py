import sys
from .__init__ import experiment_name 
print(experiment_name(),file=sys.stdout)
sys.exit(0)
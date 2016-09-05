#include "TLD_V1.0.h"
#include "time.h"

TLD::TLD(const FileNode& file)
{
	mMinGridSize = (int)file["min_win"];
	///Genarator Parameters
	//initial parameters for positive examples
	mPatternSize_i = (int)file["patch_size"];
	mMaxGoodbbNum_i = (int)file["num_closest_init"];
	mWarpNuminit_i = (int)file["num_warps_init"];
	mWarpNumupdate_i = (int)file["num_warps_update"];
	mNoiseinit_f = (float)file["noise_init"];
	mAngleinit_f = (float)file["angle_init"];
	mScaleinit_f = (float)file["scale_init"];
	//update parameters for positive examples
	//num_closest_update = (int)file["num_closest_update"];
	//num_warps_update = (int)file["num_warps_update"];
	mNoiseUpdate_f = (float)file["noise_update"];
	mAngleUpdate_f = (float)file["angle_update"];
	mScsleUpdate_f = (float)file["scale_update"];
	//parameters for negative examples                 
	mthrIsNExpert_f = (float)file["overlap"];
	mMaxBadbbNum_i = (int)file["num_patches"];
	mthrTrackValid = (float)file["thr_nn_valid"];
	mthrGoodOverlap_f = 0.6f;
	mthrBadOverlap_f = 0.2f;
	mFernPosterior_f = 6.0f;//����Ҫ��10�����ĸ���
	mIsLastValid_b = true;
	mFernModel_cls.read(file);
	mNNModel_cls.read(file);
}

TLD::TLD()
{
//test
}

TLD::~TLD()
{

	//delete[] mGrid_ptr;
	//mGrid_ptr = NULL;
	//printf("init...\n");
}


void TLD::init_v(const Mat& FirstFrame_cvM, const Rect& box)
{

	printf("init...\n");

	mIsCudaInit_b = mCudaInit();

	mLastbb = box;

	mbuildgrid_v(FirstFrame_cvM, box);//��ͼƬ�ָ�Ϊ��ͬ�߶ȵĴ�С����

	//	int GridSize = mGrid_vt.size();

	//for (int i = 0; i < GridSize; i++)
	//	{
	//	mGetbbOverlap(box,mGrid_vt[i]);//�õ�ÿ��������ͼƬ���ص���(Overlap)
	//	}

	mGetGoodBadbb_v();//��Overlap��Ϊgoodbox��badbox
	//mGetGoodBadbb_gpu();

	mLastbb = mBestbb;

	mFernModel_cls.PrepareRandomPoints_v(mScales);//��ÿ��box�������10*13����ԣ�����fernModel�Ľ�������ɺ󽫲���ı�

	mCalIntegralImgVariance_v(FirstFrame_cvM);//�������ͼ��Overlap����box��ͼ�񷽲����ͼ���ڼ��㲻ͬͼ��Ƭ����

	generator = PatchGenerator(0, 0, mNoiseinit_f, true, 1 - mScaleinit_f, 1 + mScaleinit_f, -mAngleinit_f*CV_PI / 180,
		mAngleinit_f*CV_PI / 180, -mAngleinit_f*CV_PI / 180, mAngleinit_f*CV_PI / 180);

	mGetCurrFernModel_v(FirstFrame_cvM, false);//�õ�fernModel����ѵ������ʼ��ʱ������false��ѧϰ����ʱ��true

	mGetNNModel_v(FirstFrame_cvM);//�õ�NNModel

	mFernModel_cls.UpdateFernModel(mCurrFern_vt);//��һ��ѧϰѵ��


	mNNModel_cls.UpdateNNmodel(mPExpert_cvM, mNExpert_vt_cvM);

	mEvaluate();//���������ı�fern��������PEx�Ƿ������ֵ

	//���ں���ѧϰʱѡȡѵ�������������ظ�����
	FernPosterior_st.Posterior = vector<float>(mGridSize_i);
	FernPosterior_st.Fern = vector<vector<int> >(mGridSize_i, vector<int>(10, 0));
}

void TLD::mCalIntegralImgVariance_v(const Mat& FirstFrame_cvM)
{
	//�������������ͼ
	mIntegralImg_cvM.create(FirstFrame_cvM.rows + 1, FirstFrame_cvM.cols + 1, CV_32F);
	mIntegralSqImg_cvM.create(FirstFrame_cvM.rows + 1, FirstFrame_cvM.cols + 1, CV_64F);

	integral(FirstFrame_cvM, mIntegralImg_cvM, mIntegralSqImg_cvM);

	//�������box��ͼƬ����
	Scalar Mean, StdDev;
	meanStdDev(FirstFrame_cvM(mBestbb), Mean, StdDev);
	mBestbbVariance_d = pow(StdDev.val[0], 2)*0.5;

	printf("BestbbVariance_d:%f\n", mBestbbVariance_d);
}

void TLD::mbuildgrid_v(const Mat& FirstFrame, const Rect& box)
{
	const float Shift_con_f = 0.1; //ɨ�贰�ڲ���Ϊ ���ߵ� 10%
	const float Scales_con_ary_f[21] = {  //�߶�����ϵ��Ϊ y=0.16151  (X=1),y=0.16151*1.2*(x-1) ��2<=x<=21������21�ֳ߶ȱ任
		0.16151, 0.19381, 0.23257, 0.27908, 0.33490, 0.40188, 0.48225,
		0.57870, 0.69444, 0.83333, 1, 1.20000, 1.44000, 1.72800,
		2.07360, 2.48832, 2.98598, 3.58318, 4.29982, 5.15978, 6.19174 };

	int width_i, height_i, minBBside_i;
	int sc = 0;
	//	BoundingBox bb_s;

	mGridSize_i = 0;
	for (int s = 0; s < 21; s++)
	{
		width_i = round((float)box.width*Scales_con_ary_f[s]);
		height_i = round((float)box.height*Scales_con_ary_f[s]);
		minBBside_i = min(width_i, height_i);

		//ÿ��grid����С��15*15
		if (minBBside_i<mMinGridSize || width_i>FirstFrame.cols || height_i>FirstFrame.rows)
			continue;

		//mScales.push_back(Size(width_i, height_i));
		int step = round((float)minBBside_i*Shift_con_f);

		for (int y = 1; y < FirstFrame.rows - height_i; y += step)
		{
			for (int x = 1; x < FirstFrame.cols - width_i; x += step)
			{
				mGridSize_i++;
			}
		}

	}

	mGrid_ptr = new BoundingBox[mGridSize_i];

		
	if (mIsCudaInit_b)
	{
		int GridIdx_i = 0;
		for (int s = 0; s < 21; s++)
		{
			width_i = round((float)box.width*Scales_con_ary_f[s]);
			height_i = round((float)box.height*Scales_con_ary_f[s]);
			minBBside_i = min(width_i, height_i);

			//ÿ��grid����С��15*15
			if (minBBside_i<mMinGridSize || width_i>FirstFrame.cols || height_i>FirstFrame.rows)
				continue;

			mScales.push_back(Size(width_i, height_i));
			int step = round((float)minBBside_i*Shift_con_f);

			for (int y = 1; y < FirstFrame.rows - height_i; y += step)
			{
				for (int x = 1; x < FirstFrame.cols - width_i; x += step)
				{

					mGrid_ptr[GridIdx_i].x = x;
					mGrid_ptr[GridIdx_i].y = y;
					mGrid_ptr[GridIdx_i].width = width_i;
					mGrid_ptr[GridIdx_i].height = height_i;
					mGrid_ptr[GridIdx_i].sidx = sc;
					//mGrid_ptr[GridIdx_i].overlap = mGetbbOverlap(box, mGrid_ptr[GridIdx_i]);
					GridIdx_i++;
				}
			}
			sc++;
		}//end of for (int s = 0; s < 21; s++)
		mGetAllbbOverlap_gpu(box);
	}
	else
	{
		int GridIdx_i = 0;
		for (int s = 0; s < 21; s++)
		{
			width_i = round((float)box.width*Scales_con_ary_f[s]);
			height_i = round((float)box.height*Scales_con_ary_f[s]);
			minBBside_i = min(width_i, height_i);

			//ÿ��grid����С��15*15
			if (minBBside_i<mMinGridSize || width_i>FirstFrame.cols || height_i>FirstFrame.rows)
				continue;

			mScales.push_back(Size(width_i, height_i));
			int step = round((float)minBBside_i*Shift_con_f);

			for (int y = 1; y < FirstFrame.rows - height_i; y += step)
			{
				for (int x = 1; x < FirstFrame.cols - width_i; x += step)
				{
					

					mGrid_ptr[GridIdx_i].x = x;
					mGrid_ptr[GridIdx_i].y = y;
					mGrid_ptr[GridIdx_i].width = width_i;
					mGrid_ptr[GridIdx_i].height = height_i;
					mGrid_ptr[GridIdx_i].sidx = sc;
					mGrid_ptr[GridIdx_i].overlap = mGetbbOverlap(box, mGrid_ptr[GridIdx_i]);
					GridIdx_i++;
				}
			}
			sc++;
		}//end of for (int s = 0; s < 21; s++)
	}
	
}

float TLD::mGetbbOverlap(const BoundingBox bb1, const BoundingBox bb2)
{
	//���ص�����0
	if (bb1.x > bb2.x + bb2.width) { return 0.0; }
	if (bb1.y > bb2.y + bb2.height) { return 0.0; }
	if (bb1.x + bb1.width < bb2.x) { return 0.0; }
	if (bb1.y + bb1.height < bb2.y) { return 0.0; }

	int xOverlap_f = min(bb1.x + bb1.width, bb2.x + bb2.width) - max(bb1.x, bb2.x);
	int yOverlap_f = min(bb1.y + bb1.height, bb2.y + bb2.height) - max(bb1.y, bb2.y);

	int OverlapArea_f = xOverlap_f*yOverlap_f;
	int SumArea_f = bb1.width*bb1.height + bb2.width*bb2.height - OverlapArea_f;

	return (float)OverlapArea_f / SumArea_f;

}


void TLD::mGetGoodBadbb_v()
{
	mBestbb.overlap = 0;

	mGoodbb_i_vt.clear();
	mBadbb_i_vt.clear();

	for (int i = 0; i < mGridSize_i; i++)
	{
		if (mGrid_ptr[i].overlap>mBestbb.overlap)//�ҳ��ص�����ߵ�bb
		{
			mBestbb = mGrid_ptr[i];
		}

		if (mGrid_ptr[i].overlap > mthrGoodOverlap_f)//�ҳ��ص��ȴﵽ�õ�Ҫ���bb��ţ���ֵ0.6
		{
			mGoodbb_i_vt.push_back(i);
		}
		else if (mGrid_ptr[i].overlap < mthrBadOverlap_f)//�ҳ��ص��ȴﵽ����Ҫ���bb��ţ���ֵ0.2
		{
			mBadbb_i_vt.push_back(i);
		}
	}

	printf("Best Box: %d %d %d %d\n", mBestbb.x, mBestbb.y, mBestbb.width, mBestbb.height);


	if (mGoodbb_i_vt.size()>mMaxGoodbbNum_i)//�����ص�������10��
	{
		//ʹgoodbb��Ŀ�������������
		nth_element(mGoodbb_i_vt.begin(), mGoodbb_i_vt.begin() + mMaxGoodbbNum_i, mGoodbb_i_vt.end(), OComparator(mGrid_ptr));
		mGoodbb_i_vt.resize(mMaxGoodbbNum_i);
	}

	mGetGoodbbHull_v();//��ÿ�ס����box�ľ���
}

void TLD::mGetGoodbbHull_v()
{
	int Minx = INT_MAX;
	int Miny = INT_MAX;
	int MaxW = INT_MIN;
	int MaxH = INT_MIN;

	int idx;

	//��ÿ�ס����box�ľ���
	for (int i = 0; i < mGoodbb_i_vt.size(); i++)
	{
		idx = mGoodbb_i_vt[i];

		if (mGrid_ptr[idx].x < Minx)//��Сԭ��x����
			Minx = mGrid_ptr[idx].x;

		if (mGrid_ptr[idx].y < Miny)//��Сԭ��y����
			Miny = mGrid_ptr[idx].y;

		if (mGrid_ptr[idx].x + mGrid_ptr[idx].width > MaxW)//����width
			MaxW = mGrid_ptr[idx].x + mGrid_ptr[idx].width;

		if (mGrid_ptr[idx].y + mGrid_ptr[idx].height > MaxH)//����height
			MaxH = mGrid_ptr[idx].y + mGrid_ptr[idx].height;
	}

	mGoodbbHull.x = Minx;
	mGoodbbHull.y = Miny;
	mGoodbbHull.width = MaxW - Minx;
	mGoodbbHull.height = MaxH - Miny;
}

void TLD::mGetCurrFernModel_v(const Mat& frame_cvM, bool isUpdate)
{
	mCurrFern_vt.clear();

	Mat BlurFrame_cvM;
	Mat GoodHullOCR_cvM;

	GaussianBlur(frame_cvM, BlurFrame_cvM, Size(9, 9), 1.5);//ȡ������˹ƽ����ͼƬ
	GoodHullOCR_cvM = BlurFrame_cvM(mGoodbbHull);//ȡ����˹ƽ����goodbox���������ڴ˴�������任

	//ȡGoodbbHull��������
	Point2f pt_pt32f(mGoodbbHull.x + (mGoodbbHull.width - 1)*0.5f, mGoodbbHull.y + (mGoodbbHull.height - 1)*0.5f);

	int nFern = mFernModel_cls.mGetFernNum();
	vector<int> fern(nFern);

	//�˴��ǳ�ʼ��ʱ���Ժ�ѵ��ʱҪ���fern��Ŀ��ͬ
	int warpNum;
	if (isUpdate)
	{
		warpNum = mWarpNumupdate_i;//mWarpNumupdate_i=10
	}
	else
	{
		warpNum = mWarpNuminit_i;//mWarpNuminit_i=20
	}


	mCurrFern_vt.reserve(warpNum*mGoodbb_i_vt.size() + mBadbb_i_vt.size());

	RNG& rng = theRNG();

	int idx;//goodbb������
	Mat patch_cvM;

	for (int i = 0; i<warpNum; i++)
	{

		if (i>0)//��һ����ԭʼ������˹�任ͼ�񣬲���������任
		{
			generator(frame_cvM, pt_pt32f, GoodHullOCR_cvM, mGoodbbHull.size(), rng);
		}

		for (int b = 0; b < mGoodbb_i_vt.size(); b++)
		{
			idx = mGoodbb_i_vt[b];//good_boxes����������� grid ������ 

			patch_cvM = BlurFrame_cvM(mGrid_ptr[idx]); //�Ѿ��任�� grid[idx] ������һ��ͼ��Ƭ��ȡ����

			mFernModel_cls.GetFern_v(patch_cvM, fern, mGrid_ptr[idx].sidx);//getFeatures�����õ�

			mCurrFern_vt.push_back(make_pair(fern, true));//true����goodbox��fern
		}
	}


	if (!isUpdate)
	{
		random_shuffle(mBadbb_i_vt.begin(), mBadbb_i_vt.end());//�������badbox˳��

		double thrThrow = mBestbbVariance_d*0.5f;

		vector<vector<int>> badBBFern;
		for (int b = 0; b < mBadbb_i_vt.size(); b++)
		{
			idx = mBadbb_i_vt[b];
			if (mGetVariance(mGrid_ptr[idx])<thrThrow) //������Ϊ����̫С����Ϊ������ȥ��
				continue;
			patch_cvM = frame_cvM(mGrid_ptr[idx]);

			mFernModel_cls.GetFern_v(patch_cvM, fern, mGrid_ptr[idx].sidx);

			badBBFern.push_back(fern);
		}

		int half = ceil(badBBFern.size()*0.5f);//����ȡһ����Ŀ��һ�����ڳ�ʼ��ѵ����һ�����������ı����

		for (int i = 0; i < half; i++)
			mCurrFern_vt.push_back(make_pair(badBBFern[i], false));
		for (int i = half; i < badBBFern.size(); i++)
			mFernTest.push_back(badBBFern[i]);

		//������Һõ�fern�ͻ���fern˳��
		int nCurrFernSize_i = mCurrFern_vt.size();
		vector<int> ind(nCurrFernSize_i);

		for (int i = 0; i < nCurrFernSize_i; i++)//���ڴ��ҵ����
		{
			ind[i] = i;
		}
		random_shuffle(ind.begin(), ind.end());

		int k = 0;

		vector<pair<vector<int>, bool>> temp = mCurrFern_vt;

		for (int i = 0; i < nCurrFernSize_i; i++)
		{
			mCurrFern_vt[ind[k]] = temp[i];
			k++;
		}

	}

}


double TLD::mGetVariance(const BoundingBox& bb)
{

	
	double leftup, leftdown, rightup, rightdown;
	double Mean;
	double SqMean;

	rightdown = mIntegralImg_cvM.at<int>(bb.y + bb.height, bb.x + bb.width);
	leftdown = mIntegralImg_cvM.at<int>(bb.y + bb.height, bb.x);
	rightup = mIntegralImg_cvM.at<int>(bb.y, bb.x + bb.width);
	leftup = mIntegralImg_cvM.at<int>(bb.y, bb.x);

	Mean = (rightdown + leftup - leftdown - rightup) / ((double)bb.area());

	rightdown = mIntegralSqImg_cvM.at<double>(bb.y + bb.height, bb.x + bb.width);
	leftdown = mIntegralSqImg_cvM.at<double>(bb.y + bb.height, bb.x);
	rightup = mIntegralSqImg_cvM.at<double>(bb.y, bb.x + bb.width);
	leftup = mIntegralSqImg_cvM.at<double>(bb.y, bb.x);

	SqMean = (rightdown + leftup - leftdown - rightup) / ((double)bb.area());

	return SqMean - Mean*Mean;  //����=E(X^2)-(EX)^2   EX��ʾ��ѧ����������ֵ  ���������⹫ʽ  

}

void TLD::mGetPattern_v(const Mat& Img, Mat& pattern, Scalar& StdDev)
{
	resize(Img, pattern, Size(mPatternSize_i, mPatternSize_i));//��һ��Ϊ15*15

	Scalar mean;
	meanStdDev(pattern, mean, StdDev);

	pattern.convertTo(pattern, CV_32F);
	pattern = pattern - mean.val[0];//ʹͼ��Ƭ��ֵΪ0
}

void TLD::mGetNNModel_v(const Mat& frame_cvM)
{
	Scalar dummy;
	mGetPattern_v(frame_cvM(mBestbb), mPExpert_cvM, dummy);//�õ���ǰ֡����Ϊ��pר�ң������box��ͼ�񣬴�����ѵ��NNmodel

	mNExpert_vt_cvM.resize(mMaxBadbbNum_i);

	int idx;//����box������

	for (int i = 0; i < mMaxBadbbNum_i; i++)
	{
		idx = mBadbb_i_vt[i];

		mGetPattern_v(frame_cvM(mGrid_ptr[idx]), mNExpert_vt_cvM[i], dummy);//�õ���ǰ֡����Ϊ��nר�ң�������ѵ��NNmodel
	}

	int half = ceil(mNExpert_vt_cvM.size()*0.5f);

	//����ȡһ����Ŀ��һ������ѵ����һ�����������ı����
	mNNTest.assign(mNExpert_vt_cvM.begin() + half, mNExpert_vt_cvM.end());
	mNExpert_vt_cvM.resize(half);

}

void TLD::mEvaluate()
{
	float fconf;

	for (int i = 0; i < mFernTest.size(); i++)
	{
		fconf = mFernModel_cls.GetFernPosterior(mFernTest[i]);
		if (fconf>mFernModel_cls.mthrP)
		{
			mFernModel_cls.mthrP = fconf;
		}
	}

	bool dummy1, dummy2;
	float rconf, cconf;
	for (int i = 0; i < mNNTest.size(); i++)
	{
		mNNModel_cls.GetNNConf(mNNTest[i], dummy1, dummy2, rconf, cconf);
		if (rconf>mNNModel_cls.mthrUpdatePEx)
		{
			mNNModel_cls.mthrUpdatePEx = rconf;
		}
	}

	if (mNNModel_cls.mthrUpdatePEx > mthrTrackValid)
	{
		mthrTrackValid = mNNModel_cls.mthrUpdatePEx;
	}
}

void TLD::processFrame(const Mat& CurrFrame_con_cvM, const Mat& NextFrame_con_cvM, BoundingBox& Nextbb, bool& lastboxFound)
{
	if (lastboxFound)
	{
		mtrack_v(CurrFrame_con_cvM, NextFrame_con_cvM);
	}
	else
	{
		mIsTracked_b = false;
	}
	mdetect_v(NextFrame_con_cvM);



	if (mIsTracked_b)
	{
		mIsLastValid_b = mIsTrackValid_b;
		Nextbb = mTrackbb;
		printf("track successfully!\n");
		if (mIsDetected_b)
		{
			mClusterbb.clear();
			mClusterCconf.clear();

			mCluster(mDetectedbb, mDetectCconf, mClusterbb, mClusterCconf);//�����ٵ���box����

			int ClusterbbSize = mClusterbb.size();
			printf("Found %d clusters\n", mClusterbb.size());

			int confidentDetNum = 0;
			int ConfDetidx;

			for (int i = 0; i < ClusterbbSize; i++)
			{
				//����⵽�ľ����box��overlap����ٵ�boxС��0.5������NNģ�͵ĶԱȵı������ƶ��Ǿ�����box��
				//��Ϊ�þ�����box����Ч��
				if (mGetbbOverlap(mTrackbb, mClusterbb[i])<0.5&&mClusterCconf[i]>mTrackedCconf)
				{
					confidentDetNum++;
					ConfDetidx = i;
				}
			}

			if (1 == confidentDetNum)
			{
				printf("Found a better match..reinitializing tracking\n");
				Nextbb = mClusterbb[ConfDetidx];
				mIsLastValid_b = false;
			}
			else
			{
				int cx = 0, cy = 0, cw = 0, ch = 0;
				int closeNum = 0;

				for (int i = 0; i <mDetectedbb.size(); i++)
				{
					if (mGetbbOverlap(mDetectedbb[i], mTrackbb)>0.7)
					{
						cx += mDetectedbb[i].x;
						cy += mDetectedbb[i].y;
						cw += mDetectedbb[i].width;
						ch += mDetectedbb[i].height;
						closeNum++;
					}
				}

				if (closeNum > 0)
				{
					//�����10������ƽ��mTrackbb��detectbbȨ�أ�ʹ�����һ�£�detectbbһ��Ϊ10����
					Nextbb.x = round((float)(mTrackbb.x * 10 + cx) / (float)(10 + closeNum));
					Nextbb.y = round((float)(mTrackbb.y * 10 + cy) / (float)(10 + closeNum));
					Nextbb.width = round((float)(mTrackbb.width * 10 + cw) / (float)(10 + closeNum));
					Nextbb.height = round((float)(mTrackbb.height * 10 + ch) / (float)(10 + closeNum));
					printf("Track BB:x%d y%d w%d h%d\n", mTrackbb.x, mTrackbb.y, mTrackbb.width, mTrackbb.height);
					printf("Average BB:x%d y%d w%d h%d\n", Nextbb.x, Nextbb.y, Nextbb.width, Nextbb.height);
				}
				else
				{
					printf("No close detections were found\n");
				}
			}//end of else

		}//end of if (mIsDetected_b)

	}//end of if (mIsTracked_b)

	else
	{
		printf("Not tracking..\n");
		mIsLastValid_b = false;
		lastboxFound = false;

		if (mIsDetected_b)
		{
			mClusterbb.clear();
			mClusterCconf.clear();

			mCluster(mDetectedbb, mDetectCconf, mClusterbb, mClusterCconf);

			if (mClusterbb.size() == 1)
			{
				Nextbb = mClusterbb[0];
				printf("Confident detection..reinitializing tracker\n");
				lastboxFound = true;
			}
		}

	}

	mLastbb = Nextbb;

	if (mIsLastValid_b)
	{
		mlearn_v(NextFrame_con_cvM);
	}

}

void TLD::mtrack_v(const Mat& CurrFrame_con_cvM, const Mat& NextFrame_con_cvM)
{
	printf("[track]\n");

	CurrPoints_vt_cvP32.clear();
	NextPoints_vt_cvP32.clear();

	tracker.throwPoint_v(CurrPoints_vt_cvP32, mLastbb);//������10*10=100����

	if (CurrPoints_vt_cvP32.size()<1)
	{
		printf("BB= %d %d %d %d, Points not generated\n", mLastbb.x, mLastbb.y, mLastbb.width, mLastbb.height);
		mIsTracked_b = false;
		mIsTrackValid_b = false;
		return;
	}

	//Ԥ����һ֡��
	bool tracked = tracker.getPredictPt(CurrFrame_con_cvM, NextFrame_con_cvM, CurrPoints_vt_cvP32, NextPoints_vt_cvP32);

	if (tracked)
	{
		//��Ԥ�⵽�ĵ���Ԥ����һ֡Ŀ��
		tracker.PredictObj_v(CurrPoints_vt_cvP32, NextPoints_vt_cvP32, mLastbb, mTrackbb);

		//��Ԥ�����̫���Ԥ��box����ͼ��
		if (tracker.mGetBackwardErrMedian()>10 || mTrackbb.x>NextFrame_con_cvM.cols || mTrackbb.y>NextFrame_con_cvM.rows || mTrackbb.br().x < 1 || mTrackbb.br().y <1)
		{
			mIsTracked_b = false;
			printf("Too unstable predictions FB error=%f\n", tracker.mGetBackwardErrMedian());
			return;
		}

		mIsTracked_b = true;
		//��֤Ԥ��box���в��ֶ���ͼ����
		BoundingBox bb;
		bb.x = max(mTrackbb.x, 0);
		bb.y = max(mTrackbb.y, 0);
		bb.width = min(min(NextFrame_con_cvM.cols - mTrackbb.x, mTrackbb.width), min(mTrackbb.width, mTrackbb.br().x));
		bb.height = min(min(NextFrame_con_cvM.rows - mTrackbb.y, mTrackbb.height), min(mTrackbb.height, mTrackbb.br().y));


		Scalar stdDev;
		Mat pattern;
		bool dummy1, dummy2;
		float dummy3;

		mGetPattern_v(NextFrame_con_cvM(bb), pattern, stdDev);
		mNNModel_cls.GetNNConf(pattern, dummy1, dummy2, dummy3, mTrackedCconf);//mTrackedCconf�����ж��Ƿ�ʹ�ü�⵽��box

		mIsTrackValid_b = mIsLastValid_b;
		//if (mTrackedCconf>mthrTrackValid)//0.65
		if (mTrackedCconf>0.6)
		{
			mIsTrackValid_b = true;
		}

	}
	else
	{
		printf("No point tracked!\n");
		mIsTracked_b = false;
	}


}

void TLD::mdetect_v(const Mat& NextFrame_con_cvM)
{
	printf("[detect]\n");

	mDetectedbb.clear();
	mDetectCconf.clear();

	mDetectvar_st.bbidx_i_vt.clear();
	mDetectvar_st.pattern_vt_cvM.clear();


	integral(NextFrame_con_cvM, mIntegralImg_cvM, mIntegralSqImg_cvM);//���»���ͼ


	double FernPosterior;
	vector<int> fern_vt(mFernModel_cls.mGetFernNum());

	Mat img;
	img.create(NextFrame_con_cvM.rows, NextFrame_con_cvM.cols, CV_8U);
	GaussianBlur(NextFrame_con_cvM, img, Size(9, 9), 1.5);//�ø�˹ģ�����룬��Ϊѵ��ʱ������õ�ͼ���ȡfern������ҲӦ��Ӧ



	for (int i = 0; i < mGridSize_i; i++)
	{
		//���������
		if (mGetVariance(mGrid_ptr[i]) >= mBestbbVariance_d)
		{
			//Fern������
			mFernModel_cls.GetFern_v(img(mGrid_ptr[i]), fern_vt, mGrid_ptr[i].sidx);
			FernPosterior = mFernModel_cls.GetFernPosterior(fern_vt);
			//���ں���ѧϰʱѡȡѵ�������������ظ�����
			FernPosterior_st.Posterior[i] = FernPosterior;
			FernPosterior_st.Fern[i] = fern_vt;

			if (FernPosterior>mFernPosterior_f)//mFernPosterior_f = 6
			{
				mDetectvar_st.bbidx_i_vt.push_back(i);
			}

		}
		else
		{
			FernPosterior_st.Posterior[i] = 0.0;
		}
	}

	int PassbbSize = mDetectvar_st.bbidx_i_vt.size();
	//��ͨ����grid̫��ʱ������FernPosterior���ǰ100
	if (PassbbSize > 100)
	{
		nth_element(mDetectvar_st.bbidx_i_vt.begin(), mDetectvar_st.bbidx_i_vt.begin() + 100, mDetectvar_st.bbidx_i_vt.end(), DetComparator(FernPosterior_st.Posterior));
		mDetectvar_st.bbidx_i_vt.resize(100);
		PassbbSize = 100;
	}

	int idx;
	bool dummy, dummy1;
	Scalar dummy2;

	mDetectvar_st.pattern_vt_cvM.resize(PassbbSize);
	vector<float> rconf_f_vt(PassbbSize);
	vector<float> cconf_f_vt(PassbbSize);

	//NN������
	for (int i = 0; i < PassbbSize; i++)
	{
		idx = mDetectvar_st.bbidx_i_vt[i];
		//��һ��
		mGetPattern_v(NextFrame_con_cvM(mGrid_ptr[idx]), mDetectvar_st.pattern_vt_cvM[i], dummy2);
		//ȡ����NNģ�����ƶ�
		mNNModel_cls.GetNNConf(mDetectvar_st.pattern_vt_cvM[i], dummy, dummy1, rconf_f_vt[i], cconf_f_vt[i]);

		//if (mDetectvar_st.rconf_f_vt[i]>mNNModel_cls.mthrUpdatePEx)//0.65
		if (rconf_f_vt[i]>mNNModel_cls.mthrUpdatePEx)
		{
			mDetectedbb.push_back(mGrid_ptr[idx]);//����ͨ����box
			mDetectCconf.push_back(cconf_f_vt[i]);//ͨ��box�ı������ƶ�
		}
	}

	if (mDetectedbb.size() > 0)
	{
		printf("Found %d box pass the filter\n", mDetectedbb.size());
		mIsDetected_b = true;
	}
	else
	{
		printf("No box pass the filter\n");
		mIsDetected_b = false;
	}
}

void TLD::mlearn_v(const Mat& NextFrame_con_cvM)
{
	printf("[learn]\n");
	//��֤���ᳬ��ͼ��
	BoundingBox Nextbb;
	Nextbb.x = max(mLastbb.x, 0);
	Nextbb.y = max(mLastbb.y, 0);
	Nextbb.width = min(min(NextFrame_con_cvM.cols - mLastbb.x, mLastbb.width), min(mLastbb.width, mLastbb.br().x));
	Nextbb.height = min(min(NextFrame_con_cvM.rows - mLastbb.y, mLastbb.height), min(mLastbb.height, mLastbb.br().y));

	Mat pattern;
	Scalar stdDev;
	mGetPattern_v(NextFrame_con_cvM(Nextbb), pattern, stdDev);

	if (pow(stdDev.val[0], 2) < mBestbbVariance_d)//����̫С����ѵ��
	{
		printf("Low variance!Not train!\n");
		mIsLastValid_b = false;
		return;
	}

	bool dummy1;
	bool isSim2NEx_b;
	float rconf, cconf;

	mNNModel_cls.GetNNConf(pattern, dummy1, isSim2NEx_b, rconf, cconf);

	if (isSim2NEx_b)//��ʶ��Ϊ����������ѵ��
	{
		printf("Pattern in negative Data, Not train\n");
		mIsLastValid_b = false;
		return;
	}

	if (rconf < 0.5)//�����������ƶ�̫�ͣ���ѵ��
	{
		printf("Fast change!Not train\n");
		mIsLastValid_b = false;
		return;
	}


	//for (int i = 0; i < mGridSize_i; i++)
	//{
	//	mGrid_ptr[i].overlap = mGetbbOverlap(Nextbb, mGrid_ptr[i]);//��ȡ��Ԥ�⵽��Ŀ�����box��overlap
	//}
	if (mIsCudaInit_b)
	{
		mGetAllbbOverlap_gpu(Nextbb);
	}

	//mGetGoodBadbb_v();//�õ�goodbox��badbox

	mGetGoodBadbb_gpu();

	if (mGoodbb_i_vt.size()>0)
	{
		mGetCurrFernModel_v(NextFrame_con_cvM, true);//�ȵõ�goodbox��fern����ѵ��
	}
	else
	{
		mIsLastValid_b = false;
		printf("No good boxes..Not training");
		return;
	}


	int idx;
	for (int i = 0; i<mBadbb_i_vt.size(); i++)
	{
		idx = mBadbb_i_vt[i];
		if (FernPosterior_st.Posterior[idx] >= 1){ //����box��fern���ʴ���1���õ�badbox��fern����ѵ��
			mCurrFern_vt.push_back(make_pair(FernPosterior_st.Fern[idx], false));
		}
	}

	mNExpert_vt_cvM.clear();

	int DetbbSize = mDetectvar_st.bbidx_i_vt.size();

	for (int i = 0; i<DetbbSize; i++){
		idx = mDetectvar_st.bbidx_i_vt[i];//��ͨ�������fern��������box
		if (mGetbbOverlap(mLastbb, mGrid_ptr[idx]) < mthrIsNExpert_f)
			mNExpert_vt_cvM.push_back(mDetectvar_st.pattern_vt_cvM[i]);//�õ�������Nר�ҵĹ�һ��ͼ��ѵ��
	}

	Scalar dummy;
	mGetPattern_v(NextFrame_con_cvM(Nextbb), mPExpert_cvM, dummy); //�õ�������Pר�ҵĹ�һ��ͼ��ѵ��

	mFernModel_cls.UpdateFernModel(mCurrFern_vt);
	mNNModel_cls.UpdateNNmodel(mPExpert_cvM, mNExpert_vt_cvM);

	printf("%d current fern model to train\n", mCurrFern_vt.size());
	printf("%d current NExpert model to train\n", mNExpert_vt_cvM.size());
	printf("Model Update!\n");
}

bool SortBB(const BoundingBox& b1, const BoundingBox& b2)
{
	TLD t;
	if (t.mGetbbOverlap(b1, b2) < 0.5)
	{
		return false;
	}
	else
	{
		return true;
	}
}

void TLD::mCluster(const vector<BoundingBox>& Detectbb, const vector<float>& DetectbbCconf, vector<BoundingBox>& Clusterbb, vector<float>& ClusterbbCconf)
{
	int DetectbbSize = Detectbb.size();
	vector<int> categoryIdx_i_vt;
	int categoryNum_i = 1;
	switch (DetectbbSize)
	{
	case 1:
		Clusterbb = vector<BoundingBox>(1, Detectbb[0]);
		ClusterbbCconf = vector<float>(1, DetectbbCconf[0]);
		return;
		break;
	case 2:
		categoryIdx_i_vt = vector<int>(2, 0);
		if (mGetbbOverlap(Detectbb[0], Detectbb[1])<0.5)
		{
			categoryIdx_i_vt[1] = 1;
			categoryNum_i = 2;
		}
		break;
	default:
		categoryIdx_i_vt = vector<int>(DetectbbSize, 0);
		categoryNum_i = partition(Detectbb, categoryIdx_i_vt, *SortBB);
		break;
	}

	int N = 0;
	Clusterbb = vector<BoundingBox>(categoryNum_i);
	ClusterbbCconf = vector<float>(categoryNum_i);

	for (int i = 0; i < categoryNum_i; i++)
	{
		int N = 0, mx = 0, my = 0, mw = 0, mh = 0;
		float cnf = 0.f;
		for (int j = 0; j < categoryIdx_i_vt.size(); j++)
		{
			if (i == categoryIdx_i_vt[j])
			{
				Clusterbb[i].x += Detectbb[j].x;
				Clusterbb[i].y += Detectbb[j].y;
				Clusterbb[i].width += Detectbb[j].width;
				Clusterbb[i].height += Detectbb[j].height;
				ClusterbbCconf[i] += DetectbbCconf[j];
				cnf += DetectbbCconf[j];
				N++;
			}
		}
		if (N > 0)
		{
			Clusterbb[i].x = round(mx / N);
			Clusterbb[i].y = round(my / N);
			Clusterbb[i].width = round(mw / N);
			Clusterbb[i].height = round(mh / N);
			ClusterbbCconf[i] = cnf / N;
		}
	}

}

bool TLD::mCudaInit()
{
	int count_i;
	cudaGetDeviceCount(&count_i);

	if (count_i == 0)
	{
		return false;
	}

	cudaDeviceProp prop;
	int i = 0;
	for (; i < count_i; i++)
	{
		cudaGetDeviceProperties(&prop, i);
		if (prop.deviceOverlap)
			break;
	}

	if (i == count_i)
		return false;

	cudaSetDevice(i);
	return true;
}


__global__ void GetbbOverlap_kernel(int GridSize, BoundingBox* p)
{

	//__shared__ int TempBB[512][4];
	int idx = blockDim.x*blockIdx.x + threadIdx.x;

	if (idx < GridSize)
	{
		int TempBB[4];
		TempBB[0] = p[idx].x;
		TempBB[1] = p[idx].y;
		TempBB[2] = p[idx].width;
		TempBB[3] = p[idx].height;

		if (TempBB[0] > StandardBB[0] + StandardBB[2])  { p[idx].overlap = 0.f; return; }
		if (TempBB[1] >  StandardBB[1] + StandardBB[3]) { p[idx].overlap = 0.f; return; }
		if (TempBB[0] + TempBB[2] <  StandardBB[0]){ p[idx].overlap = 0.f; return; }
		if (TempBB[1] + TempBB[3] <  StandardBB[1]){ p[idx].overlap = 0.f; return; }

		int xOverlap_f = min(TempBB[0] + TempBB[2], StandardBB[0] + StandardBB[2]) - max(TempBB[0], StandardBB[0]);
		int yOverlap_f = min(TempBB[1] + TempBB[3], StandardBB[1] + StandardBB[3]) - max(TempBB[1], StandardBB[1]);

		int OverlapArea_f = xOverlap_f*yOverlap_f;
		int SumArea_f = TempBB[2] * TempBB[3] + StandardBB[2] * StandardBB[3] - OverlapArea_f;

		p[idx].overlap = (float)OverlapArea_f / SumArea_f;
		//printf("%f\n", p[idx].overlap);
		__syncthreads();
	}

}

void TLD::mGetAllbbOverlap_gpu(BoundingBox CurrBox)
{
	BoundingBox *p;
	cudaMalloc((void**)&p, sizeof(BoundingBox)* mGridSize_i);

	cudaMemcpy(p, mGrid_ptr, sizeof(BoundingBox)* mGridSize_i, cudaMemcpyHostToDevice);

	int r[4] = { CurrBox.x, CurrBox.y, CurrBox.width, CurrBox.height };
	cudaMemcpyToSymbol(StandardBB, r, sizeof(int)* 4, 0, cudaMemcpyHostToDevice);

	GetbbOverlap_kernel << <ceil(mGridSize_i / 512), 512 >> >(mGridSize_i, p);

	cudaMemcpy(mGrid_ptr, p, sizeof(BoundingBox)* mGridSize_i, cudaMemcpyDeviceToHost);

	cudaFree(p);
}

__global__ void GetGoodBadbb_kernel(int *mBB,int Size, float thrGood, float thrBad, int best_overlap,BoundingBox* grid)
{
	int idx = blockDim.x*blockIdx.x + threadIdx.x;
	mBB[idx] = -1;
	if (idx < Size)
	{
		//printf("***overlap: %.2f,thrGood: %.2f,thrBad: %.2f\n", grid[idx].overlap,thrGood,thrBad);
		if (grid[idx].overlap>best_overlap)//�ҳ��ص�����ߵ�bb
		{
			mBB[idx] = 2;
		}

		if (grid[idx].overlap > thrGood)//�ҳ��ص��ȴﵽ�õ�Ҫ���bb��ţ���ֵ0.6
		{
			mBB[idx] = 1;
		}
		else if (grid[idx].overlap < thrBad)//�ҳ��ص��ȴﵽ����Ҫ���bb��ţ���ֵ0.2
		{
			mBB[idx] = 0;
		}
	}
	__syncthreads();
	//printf("%d : %d\n", idx, mBB[idx]);
}

void TLD::mGetGoodBadbb_gpu()
{
	BoundingBox best, *grid;
	int *result = new int[mGridSize_i];
	int *mBB = new int[mGridSize_i];
	best.overlap = 0;
	cudaMalloc((void**)&best, sizeof(BoundingBox));
	cudaMalloc((void**)&grid, sizeof(BoundingBox)*mGridSize_i);
	cudaMalloc((void**)&mBB, sizeof(int)*mGridSize_i);

	cudaMemcpy(grid, mGrid_ptr, sizeof(BoundingBox)* mGridSize_i, cudaMemcpyHostToDevice);

	GetGoodBadbb_kernel << <(int)ceil(mGridSize_i/ 512), 512 >> >(mBB, mGridSize_i, mthrGoodOverlap_f, mthrBadOverlap_f, best.overlap, grid);

	cudaMemcpy(result, mBB, sizeof(int)* mGridSize_i, cudaMemcpyDeviceToHost);
	cudaMemcpy(&mBestbb, &best, sizeof(BoundingBox), cudaMemcpyDeviceToHost);

	cudaFree(&best);
	cudaFree(grid);
	cudaFree(mBB);

	for (int i = 0; i < mGridSize_i; i++)
	{
		switch (result[i])
		{
		case 0:
			mBadbb_i_vt.push_back(i);
			break;
		case 1:
			mGoodbb_i_vt.push_back(i);
			break;
		}
	}

	printf("Best Box: %d %d %d %d\n", mBestbb.x, mBestbb.y, mBestbb.width, mBestbb.height);

	if (mGoodbb_i_vt.size() > mMaxGoodbbNum_i)//�����ص�������10��
	{
		//ʹgoodbb��Ŀ�������������
		nth_element(mGoodbb_i_vt.begin(), mGoodbb_i_vt.begin() + mMaxGoodbbNum_i, mGoodbb_i_vt.end(), OComparator(mGrid_ptr));
		mGoodbb_i_vt.resize(mMaxGoodbbNum_i);
	}

	mGetGoodbbHull_v();//��ÿ�ס����box�ľ���

	delete[] result;
}
